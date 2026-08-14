use std::fmt;
use std::future::Future;
use std::time::Duration;

use anyhow::Context;
use tokio::time::Instant;

pub(crate) enum RetryDisposition {
    Transient,
    Permanent,
}

pub(crate) fn classify_sqlx_error(error: &sqlx::Error) -> RetryDisposition {
    match error {
        sqlx::Error::Io(_) => RetryDisposition::Transient,
        sqlx::Error::PoolTimedOut => RetryDisposition::Transient,
        sqlx::Error::Configuration(_)
        | sqlx::Error::Protocol(_)
        | sqlx::Error::Database(_)
        | sqlx::Error::Migrate(_) => RetryDisposition::Permanent,
        _ => RetryDisposition::Permanent,
    }
}

pub(crate) fn classify_db_error(error: &buzz_db::DbError) -> RetryDisposition {
    match error {
        buzz_db::DbError::Sqlx(error) => classify_sqlx_error(error),
        buzz_db::DbError::Migrate(_) => RetryDisposition::Permanent,
        _ => RetryDisposition::Permanent,
    }
}

pub(crate) fn classify_redis_error(error: &redis::RedisError) -> RetryDisposition {
    match error.kind() {
        redis::ErrorKind::Io
        | redis::ErrorKind::Server(
            redis::ServerErrorKind::BusyLoading | redis::ServerErrorKind::TryAgain,
        ) => RetryDisposition::Transient,
        _ => RetryDisposition::Permanent,
    }
}

pub(crate) fn classify_redis_pool_error(
    error: &deadpool_redis::PoolError,
) -> RetryDisposition {
    match error {
        deadpool_redis::PoolError::Timeout(_) => RetryDisposition::Transient,
        deadpool_redis::PoolError::Backend(error) => classify_redis_error(error),
        _ => RetryDisposition::Permanent,
    }
}

pub(crate) struct StartupRetryPolicy {
    pub(crate) deadline: Duration,
    pub(crate) initial_delay: Duration,
    pub(crate) max_delay: Duration,
    pub(crate) max_jitter: Duration,
}

impl StartupRetryPolicy {
    pub(crate) const fn production() -> Self {
        Self {
            deadline: Duration::from_secs(120),
            initial_delay: Duration::from_millis(250),
            max_delay: Duration::from_secs(5),
            max_jitter: Duration::from_millis(250),
        }
    }
}

pub(crate) enum StartupErrorCategory {
    Dns,
    ConnectionRefused,
    Timeout,
    BackendUnavailable,
}

impl fmt::Display for StartupErrorCategory {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let category = match self {
            Self::Dns => "dns",
            Self::ConnectionRefused => "connection_refused",
            Self::Timeout => "timeout",
            Self::BackendUnavailable => "backend_unavailable",
        };
        formatter.write_str(category)
    }
}

pub(crate) enum StartupAttemptError {
    Transient {
        category: StartupErrorCategory,
        error: anyhow::Error,
    },
    Permanent {
        error: anyhow::Error,
    },
}

impl StartupAttemptError {
    pub(crate) fn transient(category: StartupErrorCategory, error: anyhow::Error) -> Self {
        Self::Transient { category, error }
    }

    pub(crate) fn permanent(error: anyhow::Error) -> Self {
        Self::Permanent { error }
    }
}

pub(crate) async fn verify_redis_startup(
    pool: &deadpool_redis::Pool,
) -> Result<(), StartupAttemptError> {
    let mut connection = pool
        .get()
        .await
        .map_err(redis_pool_startup_attempt_error)?;
    let response = redis::cmd("PING")
        .query_async::<String>(&mut connection)
        .await
        .map_err(redis_startup_attempt_error)?;

    if response == "PONG" {
        Ok(())
    } else {
        Err(StartupAttemptError::permanent(anyhow::anyhow!(
            "Redis PING returned an unexpected response"
        )))
    }
}

fn redis_pool_startup_attempt_error(error: deadpool_redis::PoolError) -> StartupAttemptError {
    let category = match &error {
        deadpool_redis::PoolError::Timeout(_) => StartupErrorCategory::Timeout,
        _ => StartupErrorCategory::BackendUnavailable,
    };
    let disposition = classify_redis_pool_error(&error);
    let error = anyhow::anyhow!("Redis pool connection attempt failed");
    match disposition {
        RetryDisposition::Transient => StartupAttemptError::transient(category, error),
        RetryDisposition::Permanent => StartupAttemptError::permanent(error),
    }
}

fn redis_startup_attempt_error(error: redis::RedisError) -> StartupAttemptError {
    let disposition = classify_redis_error(&error);
    let error = anyhow::anyhow!("Redis PING failed");
    match disposition {
        RetryDisposition::Transient => {
            StartupAttemptError::transient(StartupErrorCategory::BackendUnavailable, error)
        }
        RetryDisposition::Permanent => StartupAttemptError::permanent(error),
    }
}

pub(crate) async fn retry_startup<T, F, Fut>(
    dependency: &'static str,
    policy: StartupRetryPolicy,
    mut attempt: F,
) -> anyhow::Result<T>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T, StartupAttemptError>>,
{
    let deadline = Instant::now() + policy.deadline;
    let mut retries = 0;

    loop {
        match attempt().await {
            Ok(value) => return Ok(value),
            Err(StartupAttemptError::Permanent { error }) => {
                return Err(error).context(format!(
                    "startup dependency {dependency} failed permanently"
                ));
            }
            Err(StartupAttemptError::Transient { category, error }) => {
                let remaining = deadline.saturating_duration_since(Instant::now());
                let delay = retry_delay(&policy, retries, retry_jitter(&policy));
                if remaining.is_zero() || delay > remaining {
                    let context = format!(
                        "startup dependency {dependency} exhausted transient {category} retries: {error}"
                    );
                    return Err(error).context(context);
                }

                tracing::warn!(
                    dependency,
                    attempt = retries + 1,
                    category = %category,
                    next_delay_ms = delay.as_millis(),
                    "startup dependency retry scheduled"
                );
                tokio::time::sleep(delay).await;
                retries += 1;
            }
        }
    }
}

fn retry_delay(policy: &StartupRetryPolicy, retries: u32, jitter: Duration) -> Duration {
    let multiplier = 1_u32.checked_shl(retries.min(31)).unwrap_or(u32::MAX);
    policy
        .initial_delay
        .saturating_mul(multiplier)
        .min(policy.max_delay)
        .saturating_add(jitter)
}

fn retry_jitter(policy: &StartupRetryPolicy) -> Duration {
    if policy.max_jitter.is_zero() {
        return Duration::ZERO;
    }

    let jitter_nanos = policy.max_jitter.as_nanos().min(u64::MAX.into()) as u64;
    Duration::from_nanos(rand::random::<u64>() % jitter_nanos.saturating_add(1))
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::time::Duration;

    use super::{
        classify_redis_error, classify_sqlx_error, retry_delay, retry_startup, RetryDisposition,
        StartupAttemptError, StartupErrorCategory, StartupRetryPolicy,
    };

    fn test_policy(deadline: Duration) -> StartupRetryPolicy {
        StartupRetryPolicy {
            deadline,
            initial_delay: Duration::from_millis(250),
            max_delay: Duration::from_secs(5),
            max_jitter: Duration::ZERO,
        }
    }

    #[tokio::test(start_paused = true)]
    async fn succeeds_without_sleeping_on_first_attempt() {
        let attempts = Arc::new(AtomicUsize::new(0));
        let count = Arc::clone(&attempts);
        let value = retry_startup("test", test_policy(Duration::from_secs(1)), move || {
            count.fetch_add(1, Ordering::SeqCst);
            async { Ok::<_, StartupAttemptError>(42) }
        })
        .await
        .expect("first attempt succeeds");
        assert_eq!(value, 42);
        assert_eq!(attempts.load(Ordering::SeqCst), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn retries_transient_failures_until_success() {
        let attempts = Arc::new(AtomicUsize::new(0));
        let count = Arc::clone(&attempts);
        let value = retry_startup("postgres", test_policy(Duration::from_secs(2)), move || {
            let attempt = count.fetch_add(1, Ordering::SeqCst) + 1;
            async move {
                if attempt < 3 {
                    Err(StartupAttemptError::transient(
                        StartupErrorCategory::Dns,
                        anyhow::anyhow!("unavailable"),
                    ))
                } else {
                    Ok(42)
                }
            }
        })
        .await
        .expect("third attempt succeeds");
        assert_eq!(value, 42);
        assert_eq!(attempts.load(Ordering::SeqCst), 3);
    }

    #[tokio::test(start_paused = true)]
    async fn permanent_failure_is_not_retried() {
        let attempts = Arc::new(AtomicUsize::new(0));
        let count = Arc::clone(&attempts);
        let error =
            retry_startup::<(), _, _>("postgres", test_policy(Duration::from_secs(2)), move || {
                count.fetch_add(1, Ordering::SeqCst);
                async {
                    Err(StartupAttemptError::permanent(anyhow::anyhow!(
                        "bad config"
                    )))
                }
            })
            .await
            .expect_err("permanent error fails");
        assert_eq!(attempts.load(Ordering::SeqCst), 1);
        assert!(error.to_string().contains("postgres"));
        assert!(error.to_string().contains("permanent"));
    }

    #[tokio::test(start_paused = true)]
    async fn deadline_returns_last_transient_error() {
        let attempts = Arc::new(AtomicUsize::new(0));
        let count = Arc::clone(&attempts);
        let error = retry_startup::<(), _, _>(
            "redis",
            test_policy(Duration::from_millis(300)),
            move || {
                count.fetch_add(1, Ordering::SeqCst);
                async {
                    Err(StartupAttemptError::transient(
                        StartupErrorCategory::Timeout,
                        anyhow::anyhow!("timed out"),
                    ))
                }
            },
        )
        .await
        .expect_err("deadline fails");
        assert!(attempts.load(Ordering::SeqCst) >= 2);
        assert!(error.to_string().contains("redis"));
        assert!(error.to_string().contains("timeout"));
        assert!(error.to_string().contains("timed out"));
    }

    #[test]
    fn exponential_delay_is_capped_and_jitter_is_bounded() {
        let policy = StartupRetryPolicy::production();
        assert_eq!(
            retry_delay(&policy, 0, Duration::ZERO),
            Duration::from_millis(250)
        );
        assert_eq!(
            retry_delay(&policy, 1, Duration::ZERO),
            Duration::from_millis(500)
        );
        assert_eq!(
            retry_delay(&policy, 8, Duration::ZERO),
            Duration::from_secs(5)
        );
        assert_eq!(
            retry_delay(&policy, 8, Duration::from_millis(250)),
            Duration::from_millis(5_250),
        );
    }

    #[test]
    fn sqlx_io_errors_are_transient() {
        // A classifier that treats any transport failure as permanent would
        // prevent retrying DNS convergence, refusal, timeout, and reset.
        for kind in [
            std::io::ErrorKind::NotFound,
            std::io::ErrorKind::ConnectionRefused,
            std::io::ErrorKind::TimedOut,
            std::io::ErrorKind::ConnectionReset,
        ] {
            let error = sqlx::Error::Io(std::io::Error::from(kind));
            assert!(matches!(
                classify_sqlx_error(&error),
                RetryDisposition::Transient
            ));
        }
    }

    #[test]
    fn sqlx_pool_timeout_is_transient() {
        // A classifier that marks pool exhaustion permanent would skip a
        // recoverable startup retry.
        assert!(matches!(
            classify_sqlx_error(&sqlx::Error::PoolTimedOut),
            RetryDisposition::Transient
        ));
    }

    #[test]
    fn sqlx_configuration_error_is_permanent() {
        // A classifier that retries a malformed connection string would delay
        // a startup that cannot recover without configuration changes.
        let error = sqlx::Error::Configuration(Box::new(std::io::Error::other("invalid url")));
        assert!(matches!(
            classify_sqlx_error(&error),
            RetryDisposition::Permanent
        ));
    }

    #[test]
    fn sqlx_protocol_error_is_permanent() {
        // A classifier that retries protocol failures would hide an invalid
        // database interaction rather than failing startup immediately.
        let error = sqlx::Error::Protocol("unexpected message".to_owned());
        assert!(matches!(
            classify_sqlx_error(&error),
            RetryDisposition::Permanent
        ));
    }

    #[test]
    fn redis_io_busy_loading_and_try_again_errors_are_transient() {
        // A classifier that treats Redis transport or server-recovery errors
        // as permanent would prevent startup from surviving DNS convergence,
        // connection loss, or Redis loading its dataset.
        for kind in [
            redis::ErrorKind::Io,
            redis::ErrorKind::Server(redis::ServerErrorKind::BusyLoading),
            redis::ErrorKind::Server(redis::ServerErrorKind::TryAgain),
        ] {
            let error = redis::RedisError::from((kind, "retryable Redis error"));
            assert!(matches!(
                classify_redis_error(&error),
                RetryDisposition::Transient
            ));
        }
    }

    #[test]
    fn redis_authentication_response_and_type_errors_are_permanent() {
        // A classifier that retries invalid credentials or invalid Redis
        // command/response contracts would postpone a startup that requires
        // an operator or code change to recover.
        for kind in [
            redis::ErrorKind::AuthenticationFailed,
            redis::ErrorKind::Server(redis::ServerErrorKind::ResponseError),
            redis::ErrorKind::UnexpectedReturnType,
        ] {
            let error = redis::RedisError::from((kind, "non-retryable Redis error"));
            assert!(matches!(
                classify_redis_error(&error),
                RetryDisposition::Permanent
            ));
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::time::Duration;

    use super::{retry_delay, retry_startup, StartupAttemptError, StartupErrorCategory, StartupRetryPolicy};

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
        let value = retry_startup(
            "postgres",
            test_policy(Duration::from_secs(2)),
            move || {
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
            },
        )
        .await
        .expect("third attempt succeeds");
        assert_eq!(value, 42);
        assert_eq!(attempts.load(Ordering::SeqCst), 3);
    }

    #[tokio::test(start_paused = true)]
    async fn permanent_failure_is_not_retried() {
        let attempts = Arc::new(AtomicUsize::new(0));
        let count = Arc::clone(&attempts);
        let error = retry_startup::<(), _, _>(
            "postgres",
            test_policy(Duration::from_secs(2)),
            move || {
                count.fetch_add(1, Ordering::SeqCst);
                async { Err(StartupAttemptError::permanent(anyhow::anyhow!("bad config"))) }
            },
        )
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
}

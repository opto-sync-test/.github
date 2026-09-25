use std::env;

fn fail(message: impl AsRef<str>) -> ! {
    eprintln!("canary-evidence-state: {}", message.as_ref());
    std::process::exit(2);
}

fn parse_count(name: &str, value: &str) -> u64 {
    value.parse::<u64>().unwrap_or_else(|_| fail(format!("{name} must be a non-negative integer")))
}

fn emit(state: &str, product_green: bool, reason: &str) {
    println!(
        "{{\"schema\":\"opto-sync/canary-evidence-state/v1\",\"state\":\"{state}\",\"productGreen\":{product_green},\"reason\":\"{reason}\"}}"
    );
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() != 8 {
        fail("usage: classifier <live-job> <configuration-job> <dispatch-status> <target-count> <completed-count> <successful-count> <failed-count>");
    }

    let live = args[1].as_str();
    let configuration = args[2].as_str();
    let dispatch = args[3].as_str();
    let target = parse_count("target-count", &args[4]);
    let completed = parse_count("completed-count", &args[5]);
    let successful = parse_count("successful-count", &args[6]);
    let failed = parse_count("failed-count", &args[7]);

    if completed > target || successful > completed || failed > completed {
        fail("receipt counts are internally inconsistent");
    }

    if live == "skipped" && configuration == "success" {
        emit("no-op", false, "live consumer qualification did not execute because required configuration was absent");
        return;
    }

    if matches!(live, "failure" | "cancelled" | "timed_out" | "startup_failure") {
        emit("failed", false, "live consumer qualification executed but did not complete successfully");
        return;
    }

    if live == "success" {
        if dispatch == "completed"
            && target > 0
            && completed == target
            && successful == target
            && failed == 0
        {
            emit("qualified-green", true, "all exact downstream targets completed successfully");
            return;
        }

        if dispatch == "not-configured" {
            emit("partial", false, "live graph evidence executed but downstream dispatch completion was not configured");
            return;
        }

        if matches!(dispatch, "failed" | "preflight-failed" | "dispatch-failed" | "poll-failed" | "timed-out") || failed > 0 {
            emit("failed", false, "live qualification reached downstream execution but universal success was not established");
            return;
        }

        emit("partial", false, "live evidence executed but the completion receipt does not prove universal exact-head success");
        return;
    }

    emit("blocked", false, "job state or receipt evidence is missing or insufficient for qualification");
}

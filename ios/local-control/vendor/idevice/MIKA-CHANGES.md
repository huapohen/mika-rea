# Vendored idevice

Source: https://github.com/jkcoxson/idevice
Commit: 89702099f4d7552f704f93b4526756abda319ceb
License: MIT (retained as LICENSE)

Only the idevice crate is vendored. Mika changes:

- Add `XCUITestService::run_with_rsd` to use an existing authenticated RemotePairing software tunnel without reconnecting through legacy lockdown.
- Share the original XCTest session orchestration between the existing and new entry points.
- Use the runner's actual product module name instead of defaulting non-target runners to WebDriverAgentRunner.
- Reject short SRP PIN input instead of slicing past the end and panicking.

No upstream debug tracing subscriber is enabled by Mika; pairing material and protocol payloads must never be logged.

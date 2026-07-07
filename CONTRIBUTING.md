# Contributing to Vocateca Open Core

Thanks for your interest in improving Vocateca's open core!

## Ground rules

- This repository is the **open core** of Vocateca. It deliberately excludes the macOS
  app UI, the Pro automation runner, and any account / entitlement / billing / backend
  code. Please don't add features that assume or reintroduce those — proposals that
  belong in the proprietary app will be redirected.
- Keep the core **headless and local-first**. No telemetry, no phoning home, no embedded
  credentials. Audio and transcripts stay on the user's machine.

## Development

```sh
swift build --product vocateca-cli
swift test
```

- Target the Swift 6 language mode; the package builds with strict concurrency.
- Match the surrounding code's style, naming, and comment density.
- The CLI aims for stable, scriptable `--json` output — treat those shapes as a contract
  and call out any changes.

## Pull requests

1. Open an issue describing the change first for anything non-trivial.
2. Keep PRs focused; include tests for behavioural changes.
3. Make sure `swift build` and `swift test` pass locally.
4. By submitting a contribution you agree to license it under the Apache License 2.0
   (see [LICENSE](LICENSE)).

## Security

Please do **not** file public issues for security-sensitive reports. Email
`app@vocateca.com` instead.

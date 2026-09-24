# Documentation

- [User documentation](user/): bookmark behavior and product configuration.
- [Architecture](architecture/): media, input, authentication and lifecycle.
- [Development](development/): platform matrix, acceptance, build runbooks and plans.
  [macOS 15 integration review](development/macos15-integration-review.md)
  covers the experimental fork, evidence, regression risks and linked PR plan.
  [GitHub-hosted builds](development/build/github-builds.md) covers CI scope,
  artifacts and signing boundaries.
  [Dependency maintenance](development/dependency-maintenance.md) covers update
  automation, script-pinned inputs and upgrade qualification.
  [Native media forwarding](development/investigations/native-media-forwarding.md)
  investigates preserving webcam and microphone device payloads through transport.
- [Security](security/): threat models and security-focused contracts.
  [Private information policy](security/private-information.md) defines the
  boundary between public development material and private operational notes.
- [Hardware](hardware/): qualified hardware and display data.
- [Releases](releases/): release notes.
- [Reference](reference/): retained technical reference material.

Shared wire contracts live in [protocol](../protocol/). Current work belongs in
[HANDOFF.md](../HANDOFF.md), not a growing chronology in the top-level README.

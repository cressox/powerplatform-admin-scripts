# Contributing

Thank you for contributing to this repository.

## Scope

This repository focuses on practical PowerShell scripts for Power Platform and Power BI administration, backup, and ALM support.

## Contribution Guidelines

- Keep scripts production-focused and parameter-driven.
- Prefer safe defaults and explicit opt-in switches for risky operations.
- Add clear console output (`[INFO]`, `[WARN]`) for traceability.
- Always write a run log where practical.
- Keep naming and folder structure consistent with existing scripts.

## Pull Request Checklist

- Script has `Set-StrictMode -Version Latest`.
- Error handling returns meaningful messages.
- README has been updated if behavior changed.
- New parameters are documented with examples.
- Sensitive data is not hardcoded.

## Security

Do not commit credentials, tokens, or exported customer data.
Use secure secret storage for automation scenarios.

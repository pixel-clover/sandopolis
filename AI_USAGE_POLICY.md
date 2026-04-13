# AI Usage Policy

> [!IMPORTANT]
> Sandopolis does not accept fully AI-generated pull requests.
> AI tools may be used only for assistance.
> You must understand and take responsibility for every change you submit.
>
> Read and follow [AGENTS.md](./AGENTS.md) and [CONTRIBUTING.md](./CONTRIBUTING.md).

## Our Rule

All contributions must come from humans who understand and can take full responsibility for their code.
LLMs make mistakes and cannot be held accountable.
Sandopolis is a hardware emulator, where subtle timing bugs, incorrect bus arbitration, or wrong VDP behavior can silently break real games, so human
ownership matters.

> [!WARNING]
> Maintainers may close PRs that appear to be fully or largely AI-generated.

## Getting Help

Before asking an AI, please open or comment on an issue on the [Sandopolis issue tracker](https://github.com/pixel-clover/sandopolis/issues).
There are no silly questions, and emulator-specific topics (68K and Z80 timing, VDP DMA, YM2612 FM synthesis, and cartridge mappers) are an area where
LLMs often give confident but incorrect answers.

If you do use AI tools, use them for help (like a reference or tutor), not generatively (to fully write code for you).

## Guidelines for Using AI Tools

1. Complete understanding of every line of code you submit.
2. Local review and testing before submission, including `zig build check` and `zig build test`.
3. Personal responsibility for bugs, regressions, and compatibility problems in your contribution.
4. Disclosure of which AI tools you used in your PR description.
5. Compliance with all rules in [AGENTS.md](./AGENTS.md) and [CONTRIBUTING.md](./CONTRIBUTING.md).

### Example Disclosure

> I used Claude to help debug a failing VDP timing test.
> I reviewed the suggested fix, ran `zig build test` locally, and verified it does not regress other tests.

## Allowed (Assistive Use)

- Explanations of existing code in `src/` and `tests/`.
- Suggestions for debugging failing tests or ROM regressions.
- Help understanding Zig compiler or SDL error messages.
- Review of your own code for correctness, clarity, and style.

## Not Allowed (Generative Use)

- Generation of entire PRs or large code blocks, including new modules under `src/` or new test files under `tests/`.
- Delegation of implementation or architectural decisions to the tool, especially for timing, scheduling, or bus arbitration.
- Submission of code you do not understand.
- Generation of documentation or comments without your own review.
- Automated or bulk submission of changes produced by agents.

## About AGENTS.md

[AGENTS.md](./AGENTS.md) encodes project rules about architecture, testing, and writing style, and is structured so that LLMs can better comply with
them.
Agents may still ignore or be talked out of it; it is a best effort, not a guarantee.
Its presence does not imply endorsement of any specific AI tool or service.

## Licensing Note

Sandopolis is MIT-licensed.
The repository also references code under other licenses (for example, `external/Nuked-OPN2` is LGPL), and [AGENTS.md](./AGENTS.md) requires those
boundaries to be preserved.
AI-generated code of unclear provenance makes that harder, which is another reason to keep contributions human-authored.

## AI Disclosure

This policy was adapted, with the assistance of AI tools, from a similar policy used by other open-source projects, and was reviewed and edited by
human contributors to fit Sandopolis.

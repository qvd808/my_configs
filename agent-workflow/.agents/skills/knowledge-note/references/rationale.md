# Why the rules take this shape

Background reading. The skill executes without it; this is here for the author deciding
whether a rule should change, and for anyone asking where a rule came from.

## The genre

Diátaxis defines explanation as documentation that is "understanding-oriented" and describes
it as "a discursive treatment of a subject, that permits *reflection*"
(<https://diataxis.fr/explanation/>). The reader arrives with the question *can you tell me
about this?* and leaves able to review a decision without reconstructing the theory first.

That is the target these notes already aim at. The skill is about the single thing that
decides whether a note reaches it: the order the material arrives in.

## Where the invariants came from

I1, I2 and I3 are the three symptoms observed in practice, in descending order of frequency:
a missing goal, a deviation taught before its baseline, a decision nested inside a concept.
They are stated in full as invariants in `SKILL.md`; this file does not restate them.

The one thing worth adding here is what the three have in common. None is a density problem.
A note exhibiting them is not too long, it is out of order — which is why the skill reorders
and never shortens.

## Sources for the individual rules

**I1's boundary clause** — Diátaxis warns against letting explanation "absorb other things,"
cautioning that "allowing them to creep in interferes with the explanation itself"
(<https://diataxis.fr/explanation/>).

**I2, baseline before deviation** — this is "Introduced Abstractions", *"Before any technical
concept, establish the problem it solves"*, together with "Decoupled Explanation", *"teaching
a concept on its own before showing how it works in a specific tool"*
(<https://raw.githubusercontent.com/Xamfonos/technical-writing-best-practices/4c8e8ca5c1fd766386fad2b4a42d483d708ff066/technical-writing-style-guide.md>, *Technical Writing Style Guide*, Xamfonos/technical-writing-best-practices at
`4c8e8ca`, lines 233–247 and 383–385; fetched 2026-09-02).

**I4's fixed ordering** — the "Earned Solutions" principle, *"The problem must be established,
deepened, and clarified before presenting the fix"*, applied to a comparison rather than to a
single fix (<https://raw.githubusercontent.com/Xamfonos/technical-writing-best-practices/4c8e8ca5c1fd766386fad2b4a42d483d708ff066/technical-writing-style-guide.md>, *Technical Writing Style Guide*,
Xamfonos/technical-writing-best-practices at `4c8e8ca`, lines 287–289; fetched 2026-09-02).

**H1, concrete before general** — Diátaxis puts the same weight on staying "focused on the
concrete" (<https://diataxis.fr/explanation/>). It is a heuristic rather than an invariant
because an example that cannot be interpreted without its rule is worse than the rule stated
first.

## Why invariants and heuristics are separated

Presenting a house-style preference at the same authority as "baseline before deviation"
teaches a reader — human or agent — that the word "always" is soft here, which discounts the
rules that really are absolute. The five invariants are the ones where a reader cannot proceed
if they are broken. The heuristics are the ones where a note can be defensibly different.

## Fetching the sources

The Xamfonos style guide is a public MIT-licensed repository. Fetch it directly rather than
going through the repo page:

```
https://raw.githubusercontent.com/Xamfonos/technical-writing-best-practices/4c8e8ca5c1fd766386fad2b4a42d483d708ff066/technical-writing-style-guide.md
```

Three things to know before relying on that at run time.

- **Cite the raw URL, not the repo root.** A repository URL plus a bare filename is not a
  fetchable address. Many agent fetch tools also refuse a URL assembled by editing the path of
  a URL they have already seen, so an agent handed only the repo root cannot reliably reach
  the file in one step.
- **Do not resolve paths through `api.github.com`.** It allows 60 requests an hour
  unauthenticated, shared across a whole sandbox, and can be exhausted before the agent's
  first call. `raw.githubusercontent.com` has no such limit. `git ls-remote` also works and
  does not touch the API.
- **The URL is pinned to a commit, not to `main`.** The quotations above are exact. A branch
  URL would let the guide change underneath them and turn a correct citation into a wrong one
  silently.

If the agent using this skill has no network access, copy the guide into this directory as
`technical-writing-style-guide.md` and cite the local path alongside the upstream URL. The MIT
licence permits redistribution with the copyright notice and licence text retained.

# Architecture

High-level map of the system. Describe engineering intent, not implementation:
what the domains are, where the boundaries lie, which direction dependencies may point,
and which constraints and invariants hold system-wide. Anything the code already says
does not belong here.

## Domains

<!-- One paragraph per domain: responsibility, owning directory, what it must not know about. -->

## Boundaries and dependency direction

<!-- e.g. "Domain layer depends on nothing; Application depends on Domain; Infrastructure depends on both." -->

## Runtime flows

<!-- The two or three flows a newcomer must understand: request → … → response. -->

## System-wide constraints and invariants

<!-- Cross-cutting rules that individual features cannot override. Link the ADR that introduced each. -->

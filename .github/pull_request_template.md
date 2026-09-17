## What is true now that wasn't before

<!-- One line. The title of the commit that lands this should say the same thing. -->

## Why the old behaviour stopped being right

<!-- Not "it was a bug" — what changed in the world, or what was never
     considered. If it was always wrong, say what hid it. -->

## How you know

<!-- A probe, a measurement, a command someone else can run. If a probe's
     output changed, that probe was asserting something it no longer should —
     fix it in this PR. -->

- [ ] `./build.sh` passes, contract guards included
- [ ] Probes touching what I changed still pass and still assert the right thing

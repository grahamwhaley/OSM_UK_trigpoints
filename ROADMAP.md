# Roadmap -- OSM_UK_trigpoints

This document tracks the remaining work required to bring the OS trigpoint import to completion.
It is intended as a living document -- items should be ticked off as they are resolved, and issue
or PR references added as they are opened.

Proposed in issue [#4](https://github.com/grahamwhaley/OSM_UK_trigpoints/issues/4). Contributions and suggestions welcome.

---

## Phase 1 -- Pre-import prerequisites

*These are blockers. They must be resolved before any OSC files are submitted to OSM.*

- [ ] **Confirm OS OpenData licence compatibility with ODbL** -- verify that both the Complete
  Trig Archive and the Complete Benchmark Archive may be used in an ODbL-licensed database, and
  document the outcome in the import wiki page. The OSM import guidelines require this to be
  explicit. Issue [#10](https://github.com/grahamwhaley/OSM_UK_trigpoints/issues/10)
- [ ] **Resolve `ele` datum question** -- update OSC generation to emit ODN values into `ele:local`
  rather than `ele`; defer population of `ele` until the EGM96 conversion pipeline is confirmed
  and agreed with the community. see [Talk-GB thread, June 2026](https://lists.openstreetmap.org/pipermail/talk-gb/2026-June/032167.html). New tags implemented in code and appearing in osc and js/map files. Awaiting further review before committing decisions into the relevant import wiki page for review.
- [x] **Fix review vs edit classification logic** -- route nodes to 'review' only on positive
  disagreement between non-empty fields; nodes with absent name or ref fields should route to
  'edit' rather than 'review'. Issue [#2](https://github.com/grahamwhaley/OSM_UK_trigpoints/issues/2) now closed.
- [ ] **Agree tag schema with the community** -- resolve outstanding questions around `ref` vs
  `ref:flush_bracket`, `ref:os` vs `OS_ref`, and the `ele` / `ele:local` split; document agreed
  decisions in the import wiki page before the 14-day review period opens. Issue [#11](https://github.com/grahamwhaley/OSM_UK_trigpoints/issues/11).

---

## Phase 2 -- Data quality and code tidying

*Should be completed before the 14-day community review period opens.*

- [x] **Fix TAGS.md heading** -- the heading currently reads `man_made=trig_point` but should
  read `man_made=survey_point` to match OSM tagging practice and the rest of the documentation.
- [x] **Fix `survery_point` typo** -- correct the typo in the README and audit the R code for
  the same error.
- [ ] **Investigate missing ~1/3rd of trig data in the Benchmark Archive** -- confirm whether
  entries are genuinely absent or do not conform to the `TP` marking scheme, as noted in the
  README TODO. Issue [#12](https://github.com/grahamwhaley/OSM_UK_trigpoints/issues/12)
- [ ] **Add `source` tag to all generated OSC output** -- the tags proposal table currently marks
  this as `???`; agree and implement a value such as `OS OpenData` before generating final OSC
  files. <!-- no issue yet -->
- [x] **Improve OSC output graph labelling** -- add axis labels and legends to the diagnostic
  plots, as noted in the README TODO. Fixed in Issue [#6](https://github.com/grahamwhaley/OSM_UK_trigpoints/issues/6)
- [x] **Document generated output file formats** -- add descriptions of the generated data files
  to the README, as noted in the README TODO. The `OSC` files have some detail in the README now, and the `js` files are pretty specific to the slippy map and not really 'use visible' unless you are devoping, so I think this is done for now.

---

## Phase 3 -- Import execution

*The formal import process.*

- [ ] **Publish import wiki page** on the OSM wiki, covering methodology, tag schema, licence
  compatibility, and data sources. <!-- no issue yet -->
- [ ] **Send formal import plan email** to imports@openstreetmap.org, opening the 14-day
  community review period. <!-- no issue yet -->
- [ ] **Refresh OSM source data** immediately before import -- the Geofabrik extract used during
  analysis will be stale by the time the import proceeds; regenerate from a current extract.
  <!-- no issue yet -->
- [ ] **Add `ref:os` to all nodes** as the primary indicator that a node has been checked or
  created against OS data, enabling automated detection of already-processed nodes in future.
  <!-- no issue yet -->
- [ ] **Wait for the 14-day review period to complete** -- 
- [ ] **Hand-fix the 5 OSM upstream nodes with existing `ref:os`** -- Fix those 5 nodes, and
  whilst there we may as well do a complete fix on them (referring to the `osc` files for guidance)
  and then wait for their results to trickle through OSM and geofabrik, and then check how the code
  handles them
- [ ] **Enable strict 'good node' checking in the code** -- Once the first 5 hand-fixed nodes have
  made it into the mainstream dataflow we can enable 'strict checking' in the code and check it both
  identifies those 5 nodes correctly, and assess how it now categorises the rest of the nodes.
- [ ] **Stage the import in tranches** -- submit new nodes, edits, and reviews as separate
  passes; do not submit all ~6,000 nodes in a single changeset. <!-- no issue yet -->
  - [ ] **Select test tranche** -- As a suggestion, we could try a small country or area such as:
    - Rutland
	- Isle of Wight
	- There is a small area SW of Edingburgh that has a good mix of all 4 categories of nodes
- [ ] **Execute small test tranche on the test/dev server** -- We should acquaint ourselves with the
  upload procedure (currently planned via JOSM) on the test server to ensure all goes smoothly. Note
  the test server is very unlikely to have the current OSM nodes upto date, so take that into account
  when undertaking the test.
- [ ] **perform first small tranche** -- Run the first tranche. Inform the community, and wait for the
  data to trickle back through before sanity checking it with a new code run.
- [ ] **Discuss/decide how to proceed** -- if first small import works, do we then do the rest in one
  go, or do we sub-divide it somehow (for instance, there are 48 ceremonial counties in England - this
  feels too large. We could go England/Scotland/Wales but that feels too few.).

---

## Phase 4 -- Post-import housekeeping

- [ ] **Update the slippy map** to reflect post-import OSM state. <!-- no issue yet -->
- [ ] **Archive or close the repository clearly** -- record the import outcome, date, changeset
  references, and any remaining manual review items. <!-- no issue yet -->
- [ ] **Document the ODN/EGM96 conversion approach** for future reference by anyone maintaining
  the elevation data. <!-- no issue yet -->

---

## Ongoing / nice-to-have

- [ ] Add `CONTRIBUTING.md` if external contributors are expected during the review period.
  <!-- no issue yet -->
- [ ] Add a `CHANGELOG` or version tagging to mark significant milestones. <!-- no issue yet -->
- [x] Consider adding `ref:GB:trigpointinguk` cross-references where TrigpointingUK waypoint
  data is available -- this key already appears in existing OSM data (TAGS.md, position 46).
  I've detailed the current state in Issue [#13](https://github.com/grahamwhaley/OSM_UK_trigpoints/issues/13). I have no current plans to add trigpointing.uk tags.

---

*Cross-references use GitHub issue/PR numbers in the form `(#N)`. Items marked `<!-- no issue yet -->`
are candidates for future issues if discussion or tracking is needed.*

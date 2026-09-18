# Migration

Existing production devices currently use a user Skill under `~/.zcode/skills/` (or the Windows equivalent).

Do not run the same-name user Skill and Plugin Skill side-by-side as the intended production state.

A controlled migration will:

1. inspect the existing Skill and broker;
2. precisely stop the old Linux/Windows broker where applicable;
3. move the old user Skill out of discovery into a rollback archive;
4. verify in a fresh ZCode session that the old Skill is no longer discovered;
5. install the Plugin;
6. open another fresh session;
7. prove the Skill path comes from the Plugin package;
8. run one read-only smoke;
9. retain the rollback archive until the Plugin path is stable.

Each device migration is separately authorized.

Windows migration will also validate the remaining evidence boundary: the Plugin-bundled default Named-Pipe broker cold-start when no prior broker/pipe exists.

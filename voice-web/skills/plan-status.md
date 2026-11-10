---
name: plan-status
description: "Where's plan 123 up to", "how's the X plan going", a plan's lead or workers
---
1. Read the plan itself: plan with its number gives state, sub-plans, linked PRs and the latest comments. Don't know the number? plan_search with a few words from the title.
2. What its lead is doing right now: paseo `ls`, find the session whose title starts with the plan number and says "lead", then `logs <lead id> --tail 15`, or read_session with the plan number. Its workers have the plan number in their titles too.
3. If it has a PR, github view shows the PR and its checks; github checks is the short CI list.
4. Say in one or two sentences where it is and whether it's waiting on anyone. If nothing is running for that plan, say so plainly. Don't guess its stage.
5. Only if they want something changed, delegate to "plan lead" with the plan number.

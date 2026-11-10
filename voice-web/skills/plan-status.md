---
name: plan-status
description: "Where's plan 123 up to", "how's the X plan going", a plan's lead or workers
---
1. paseo `ls`, find the session whose title starts with the plan number and says "lead". Its workers have the plan number in their titles too.
2. paseo `logs <lead id> --tail 15`, or read_session with the plan number. Say in one or two sentences what it's doing now and whether it's waiting on anyone.
3. If nothing is running for that plan, say so plainly. Don't guess its stage.
4. Only if they want detail the logs don't have, or want something changed, delegate to "plan lead" with the plan number.

---
name: exam-prep
description: Build a day-by-day study plan for an upcoming exam from Notion, the calendar, and free time.
---
When Sam asks for help preparing for an exam:

1. Call get_briefing (or notion_search with the course code) to find the exam date, what it covers, and its weight.
2. Call calendar_read with enough days to reach the exam to see existing commitments. Respect the 6:00–6:30am workout.
3. Work out how many days are left. Split the topics in "Covers" across those days, heaviest topics first, with the last day reserved for a practice exam and review.
4. Say the plan in two or three spoken sentences: days left, today's topic, and when the practice run is.
5. Offer to put the study blocks on the calendar. Only create events after he says yes, one calendar_create per block, 60–90 minutes each, titled "Study: <course> – <topic>".
6. Offer to save the plan to Notion with notion_create_note.

Keep it encouraging and brief. Never invent topics that aren't in the exam's Covers field; if it's empty, ask what the exam covers.

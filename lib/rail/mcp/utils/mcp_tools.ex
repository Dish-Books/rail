defmodule Rail.Mcp.Utils.McpTools do
  @moduledoc """
  The tools Rail serves itself, and which stage is offered each of them.

  Unlike everything else the proxy serves, these have no upstream, no account and
  nothing forwarded: Rail runs them. This module is only the register - what they
  are called, what they take, and who may call them - and
  `Rail.Mcp.Actions.CallRunTool` is what runs them. A name that is not on a run's
  list is a name to forward, so this is also the gate.

  Three registers, because two stages drive the same browser for different
  reasons. `@browser_tools` is the browser itself and belongs to neither: QA
  drives it to find out whether the change works, demo drives it to show that it
  does, and the page does not care which. Rail holds it, so it can hand back a
  receipt instead of a page, keep the session alive between calls, and take the
  whole thing down when the task ends. Every other stage reads code, and a
  browser would be a thing to get lost in.

  The agent never starts the browser and never names a file. Any tool opens the
  session if it is not open, and a screenshot is described rather than located -
  so nothing arriving from a model becomes a path, and there is no way to leave a
  Chrome behind by forgetting the last instruction.

  `@qa_tools` are about a pass rather than a page. `qa_plan` writes the checklist
  before anything is opened, `qa_check` marks a row off as it is reached, and
  `qa_shot` files a picture against one of those rows - which is what the human
  watching is actually shown: a list of what this pass said it would do, going
  green a row at a time. None of the three opens a browser of its own.

  `@demo_tools` are about a recording. `demo_start` is the camera, and it is the
  agent's to switch on: a run filmed from its first call to its last is a film of
  an agent working out how the application behaves, which is not the demo. So the
  rehearsal happens off camera and the take is what gets recorded. `demo_say` is
  how the agent narrates what it is about to do, stamped against the recording's
  own clock so the caption is up while the thing happens.
  """

  alias Rail.Roles.Schemas.Role

  @browser_tools [
    %{
      "name" => "browser_goto",
      "description" =>
        "Open a URL in the browser. Starts the browser if it is not already open. " <>
          "Returns where it ended up, which is not always where it was sent.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"url" => %{"type" => "string", "description" => "The URL to open."}},
        "required" => ["url"]
      }
    },
    %{
      "name" => "browser_do",
      "description" =>
        "Say what you want to be true of the current page and Rail drives until it is: \"a bill " <>
          "for Sysco dated 12 Aug 2026 for $2,500 is entered and saved\". It reads the page, acts, " <>
          "reads again, and stops when the outcome is reached or nothing offered can reach it. " <>
          "Give it the whole outcome rather than one keystroke - a step at a time is slower and " <>
          "reads worse, because each call starts again knowing nothing of the last. Nothing is " <>
          "ever invented: supply every value it will need in `values`, keyed by the field as the " <>
          "page labels it, and a field with no value stops the call and asks. A date or time field " <>
          "takes the value HTML gives it whatever the page displays: `2026-09-19`, " <>
          "`2026-09-19T14:30`, `14:30`, `2026-09`. Returns what was executed, not the page - read " <>
          "it with browser_look before you conclude anything, because reaching the end is not the " <>
          "same as the application having done the right thing.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "intent" => %{"type" => "string", "description" => "The outcome you want on this page."},
          "values" => %{
            "type" => "object",
            "description" =>
              ~s(What to type, keyed by the field's label on the page - {"Number": "QA-1", ) <>
                ~s("Date": "2026-08-12"}. Every field the outcome needs.),
            "additionalProperties" => %{"type" => "string"}
          },
          "text" => %{
            "type" => "string",
            "description" => "A single value, for an outcome that types into one field and no more."
          }
        },
        "required" => ["intent"]
      }
    },
    %{
      "name" => "browser_look",
      "description" =>
        "Read the current page as text: where it is, its title, what is visible, and what can be " <>
          "acted on. Cheaper and more exact than a screenshot - use this to check a value.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "browser_problems",
      "description" =>
        "Everything the browser complained about since this was last asked: uncaught exceptions, " <>
          "console errors, failed requests, a crashed page. Draining, so what comes back belongs " <>
          "to whatever just ran. Ask often.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "browser_stop",
      "description" =>
        "Close the browser. Not required - Rail closes it when the task moves on - but it frees " <>
          "the machine sooner when the driving is finished.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }
  ]

  @qa_tools [
    %{
      "name" => "qa_plan",
      "description" =>
        "Write the checklist for this pass, before anything is opened. Each check is one thing to " <>
          "verify in the running application, named while the answer is still unknown. Start from " <>
          "the ticket's acceptance criteria - every one of them gets at least one check quoting " <>
          "it in `criterion` - and add whatever else this change makes worth looking at. Rail " <>
          "shows the list to the human watching and marks each row off as you report it, so this " <>
          "is also how a pass says what it is going to do. Calling it again replaces the whole list, " <>
          "except that a row an earlier pass already answered keeps that answer when you list it again " <>
          "under the same key - so a second pass lists everything and drives only what has changed.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "checks" => %{
            "type" => "array",
            "description" => "Every check this pass will run, in the order you will run them.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "key" => %{"type" => "string", "description" => "Lowercase hyphenated name, unique in this list."},
                "title" => %{"type" => "string", "description" => "What this check verifies, in one line."},
                "group" => %{
                  "type" => "string",
                  "description" =>
                    ~s(The heading this row sits under, a few words - "Setup", "Acceptance checks", ) <>
                      "\"Around the change\". Rows sharing one are shown together, in the order first seen."
                },
                "criterion" => %{
                  "type" => "string",
                  "description" =>
                    "The acceptance criterion this check verifies, quoted from the ticket. Every " <>
                      "criterion needs at least one check against it, and the panel reads the " <>
                      "checklist as the answer to whether they were all covered."
                }
              },
              "required" => ["key", "title"]
            }
          }
        },
        "required" => ["checks"]
      }
    },
    %{
      "name" => "qa_check",
      "description" =>
        "Mark one checklist row as run, as soon as you have run it rather than at the end. " <>
          "`outcome` is `pass`, `fail` or `skipped`. A row you will raise a finding against is a " <>
          "`fail`, and the only exception is a defect that was already there before this change - " <>
          "the checklist and the findings are one account of the same pass, and a list of passes " <>
          "over a report of findings is a pass nobody can believe. A defect belonging to no row " <>
          "you planned means calling `qa_plan` again with the row added, then marking it.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "key" => %{"type" => "string", "description" => "The key of the check, from qa_plan."},
          "outcome" => %{"type" => "string", "enum" => ["pass", "fail", "skipped"]},
          "note" => %{"type" => "string", "description" => "One line on what you saw, or why it was skipped."}
        },
        "required" => ["key", "outcome"]
      }
    },
    %{
      "name" => "qa_shot",
      "description" =>
        "Photograph the page and file it against one check. Say what the picture is of and which " <>
          "check it is for; Rail names the file and returns the name to put in a finding's " <>
          "evidence - the name, never the picture. The human reads the checklist row by row with " <>
          "the pictures taken for each, so every check wants at least one: take it at the point " <>
          "the check asserts something, not after every keystroke.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "check" => %{"type" => "string", "description" => "The key of the check this shows, from qa_plan."},
          "name" => %{"type" => "string", "description" => "What this picture shows."}
        },
        "required" => ["check", "name"]
      }
    }
  ]

  @demo_tools [
    %{
      "name" => "demo_start",
      "description" =>
        "Start recording, and throw away anything filmed before now. Nothing is recorded until you " <>
          "call this, so signing in, reading the application and working out how the flow goes are " <>
          "all off camera - which is the point. Drive the whole walkthrough once to find out how it " <>
          "behaves, put any data you changed back, and then call this and do the run you now know. " <>
          "Calling it again starts another take and discards the last one, so a walkthrough that " <>
          "went wrong costs a retake rather than a bad video.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "demo_say",
      "description" =>
        "Narrate the next beat of the walkthrough. Say it immediately before you do the thing, " <>
          "not after: Rail stamps it against the recording's clock and the caption goes up while " <>
          "the action happens. One sentence, in the words someone who has never seen this codebase " <>
          "would use - what is about to happen and why it matters, never the mechanics of how you " <>
          "are clicking it. Name the acceptance criterion in `criterion` when the beat is what " <>
          "proves one; that is what says the walkthrough covered the ticket rather than wandered " <>
          "around the application.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "text" => %{"type" => "string", "description" => "The caption, one sentence."},
          "criterion" => %{
            "type" => "string",
            "description" => "The acceptance criterion this beat proves, quoted from the ticket."
          }
        },
        "required" => ["text"]
      }
    }
  ]

  @doc """
  The tools Rail serves this run itself: the browser for the two stages that
  drive one, and whatever else that stage reports with.
  """
  def mcp_tools(%Role{stage: :qa}), do: @browser_tools ++ @qa_tools
  def mcp_tools(%Role{stage: :demo}), do: @browser_tools ++ @demo_tools
  def mcp_tools(%Role{}), do: []
end

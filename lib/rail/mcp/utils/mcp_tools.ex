defmodule Rail.Mcp.Utils.McpTools do
  @moduledoc """
  The tools Rail serves itself, and which stage is offered each of them.

  Unlike everything else the proxy serves, these have no upstream, no account and
  nothing forwarded: Rail runs them. This module is only the register - what they
  are called, what they take, and who may call them - and
  `Rail.Mcp.Actions.CallRunTool` is what runs them. A name that is not on a run's
  list is a name to forward, so this is also the gate.

  Today every entry is the browser Rail drives for QA. Rail holds it, so it can
  hand back a receipt instead of a page, keep the session alive between calls,
  file the screenshots itself, and take the whole thing down when the task ends.
  Only a run at the QA stage is offered them: every other stage reads code, and a
  browser would be a thing to get lost in.

  The agent never starts the browser and never names a file. Any tool opens the
  session if it is not open, and a screenshot is described rather than located -
  so nothing arriving from a model becomes a path, and there is no way to leave a
  Chrome behind by forgetting the last instruction.

  Two of them are about the pass rather than the page. `qa_plan` writes the
  checklist before anything is opened and `qa_check` marks a row off as it is
  reached, which is what the human watching is actually shown: a list of what this
  pass said it would do, going green a row at a time. Neither opens a browser.
  """

  alias Rail.Roles.Schemas.Role

  @qa_tools [
    %{
      "name" => "qa_plan",
      "description" =>
        "Write the checklist for this pass, before anything is opened. Each check is one thing to " <>
          "verify in the running application, named while the answer is still unknown. Start from " <>
          "the ticket's acceptance criteria - every one of them gets at least one check quoting " <>
          "it in `criterion` - and add whatever else this change makes worth looking at. Rail " <>
          "shows the list to the human watching and marks each row off as you report it, so this " <>
          "is also how a pass says what it is going to do. Calling it again replaces the whole list.",
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
          "`outcome` is `pass`, `fail` or `skipped`. A `fail` normally has a finding behind it, but " <>
          "say so here either way - the checklist is the account of what was looked at, and the " <>
          "findings are only what went wrong.",
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
      "name" => "qa_goto",
      "description" =>
        "Open a URL in the QA browser. Starts the browser if it is not already open. " <>
          "Returns where it ended up, which is not always where it was sent.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"url" => %{"type" => "string", "description" => "The URL to open."}},
        "required" => ["url"]
      }
    },
    %{
      "name" => "qa_do",
      "description" =>
        "Carry out one instruction on the current page, in plain words: \"click Save\", " <>
          "\"open the vendor dropdown and choose Acme\". Rail works out which element that is " <>
          "and does it, taking as many actions as the instruction needs. To type, supply `text` - " <>
          "nothing is ever invented, so an instruction that reaches a field with no text supplied " <>
          "comes back asking for it. A date or time field takes the value HTML gives it whatever " <>
          "the page displays: `2026-09-19`, `2026-09-19T14:30`, `14:30`, `2026-09`. Returns what " <>
          "was actually executed, not the page.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "intent" => %{"type" => "string", "description" => "What to do, in one instruction."},
          "text" => %{"type" => "string", "description" => "The exact value to type, when the instruction types."}
        },
        "required" => ["intent"]
      }
    },
    %{
      "name" => "qa_look",
      "description" =>
        "Read the current page as text: where it is, its title, what is visible, and what can be " <>
          "acted on. Cheaper and more exact than a screenshot - use this to check a value, and " <>
          "qa_shot to check how something looks.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
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
    },
    %{
      "name" => "qa_problems",
      "description" =>
        "Everything the browser complained about since this was last asked: uncaught exceptions, " <>
          "console errors, failed requests, a crashed page. Draining, so what comes back belongs " <>
          "to the check that just ran. Ask after every check.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "qa_stop",
      "description" =>
        "Close the QA browser. Not required - Rail closes it when the task moves on - but it frees " <>
          "the machine sooner when the driving part of a pass is finished.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }
  ]

  @doc """
  The tools Rail serves this run itself, which today is the browser and only for
  QA.
  """
  def mcp_tools(%Role{stage: :qa}), do: @qa_tools
  def mcp_tools(%Role{}), do: []
end

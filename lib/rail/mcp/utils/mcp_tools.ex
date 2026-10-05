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
  does, and the page does not care which. Rail holds it, so it can keep the
  session alive between calls, film and stream it, and take the whole thing down
  when the task ends. Every other stage reads code, and a browser would be a
  thing to get lost in.

  Rail does not drive it. `browser_connect` hands the agent its tab's DevTools
  address and a driver, and the agent writes and runs its own scripts against
  it - as many steps to a script as it likes, with anything CDP can do. What
  Rail keeps is what only Rail can do: open the tab, watch it, and say what the
  browser complained about.

  The agent never starts the browser and never names a file Rail serves. Any
  tool opens the tab if it is not open, a screenshot is described rather than
  located, and a file the agent wrote is copied in under a name Rail chooses - so
  nothing arriving from a model becomes a served path, and there is no way to
  leave a tab behind by forgetting the last instruction: reconcile closes it when
  the task moves on.

  `@qa_tools` are about a pass rather than a page. `qa_plan` writes the checklist
  before anything is opened, `qa_check` marks a row off as it is reached, and
  `qa_shot` files a picture and `qa_file` an output file against one of those
  rows - which is what the human watching is actually shown: a list of what this
  pass said it would do, going green a row at a time with its evidence beside it.
  None of the four opens a browser of its own.

  Every stage hands its output over through save tools of its own, checked when
  called; review and QA each have a `save_finding`, with that stage's own fields.

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
      "name" => "browser_connect",
      "description" =>
        "Get your tab in Rail's headless Chrome and the driver to drive it with. Returns the tab's " <>
          "DevTools websocket and the path of `driver.mjs`, a zero-dependency Node module: " <>
          "`openBrowser(url)` gives you click, hover, type, press, select, typeDate, upload, goto, " <>
          "evaluate, expect, until, text, shot, resize and drainProblems, all as trusted input " <>
          "events so LiveView sees what a person's would produce. Write a script per check and run " <>
          "it with `node`; the tab stays where each script leaves it, signed in. Rail watches the " <>
          "same tab, so the panel and a demo recording show what you do. Call it again if the " <>
          "address stops answering.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "browser_problems",
      "description" =>
        "Everything the browser complained about since this was last asked: uncaught exceptions, " <>
          "console errors, failed requests, a crashed page. Draining, so what comes back belongs " <>
          "to whatever just ran. Ask often.",
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
          "what was filed for each, so a check that asserts something on screen wants a picture of " <>
          "it: take it at the point the check asserts it, not after every keystroke.",
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
      "name" => "qa_file",
      "description" =>
        "File an output file against one check: a log, a PDF, a CSV, whatever the check produced " <>
          "that proves it. Write or copy it under the QA directory first and give its path relative " <>
          "to that directory; Rail copies it in under a name of its own and returns the name to put " <>
          "in a finding's evidence. A check proved by what it writes needs no picture, and a check " <>
          "can carry both.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "check" => %{"type" => "string", "description" => "The key of the check this proves, from qa_plan."},
          "name" => %{"type" => "string", "description" => "What this file shows."},
          "path" => %{
            "type" => "string",
            "description" =>
              "Where the file is, relative to the QA directory: a log, a PDF, a CSV, any output that " <>
                "proves the check. Never absolute and never climbing out with `..`."
          }
        },
        "required" => ["check", "name", "path"]
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

  @severity %{
    "type" => "string",
    "enum" => ["blocker", "major", "minor", "nit"],
    "description" => "How much it matters."
  }
  @recommendation %{
    "type" => "string",
    "enum" => ["fix", "skip"],
    "description" => "Whether you would act on it. Your advice; a human decides."
  }
  @status %{
    "type" => "string",
    "enum" => ["open", "fixed", "not_fixed"],
    "description" =>
      "`open` for a problem that still stands; on a later pass, `fixed` or `not_fixed` for one raised before."
  }
  @finding_key %{
    "type" => "string",
    "description" =>
      "Your own name for the problem, lowercase with hyphens. Keep it the same for the same problem across " <>
        "saves and passes: saving a key again updates that finding rather than raising it twice."
  }

  @product_tools [
    %{
      "name" => "save_ticket",
      "description" =>
        "Save the ticket. The panel shows it to the human as soon as it is saved, so save a first draft as " <>
          "soon as you have one and save again after every change: each save replaces the ticket in full. " <>
          "A save in the wrong shape is refused naming each field, and the last good save stays.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string", "description" => "The ticket title, one line."},
          "description" => %{"type" => "string", "description" => "The ticket body, in markdown, verbatim."},
          "priority" => %{
            "type" => "string",
            "enum" => ["urgent", "high", "medium", "low"],
            "description" => "Left out, the issue's own priority stays."
          },
          "estimate" => %{
            "type" => "integer",
            "description" => "Points, zero or more. Left out, the issue's own estimate stays."
          }
        },
        "required" => ["title", "description"]
      }
    }
  ]

  @design_tools [
    %{
      "name" => "save_design_option",
      "description" =>
        "Save one design option once its page `<key>.html` and screenshot `<key>.png` exist in the design " <>
          "folder, and save it again whenever it changes. The panel shows each option as it is saved, while " <>
          "the others are still being built. Three options before the human picks, and only the picked one after.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "key" => %{
            "type" => "string",
            "description" => "Lowercase letters, digits and dashes. It names the option's files."
          },
          "title" => %{"type" => "string", "description" => "The option's name."},
          "summary" => %{"type" => "string", "description" => "One or two sentences: the position this option takes."},
          "good_at" => %{"type" => "array", "items" => %{"type" => "string"}, "description" => "Short phrases."},
          "costs" => %{"type" => "array", "items" => %{"type" => "string"}, "description" => "Short phrases."},
          "assumptions" => %{
            "type" => "string",
            "description" => "What you assumed, so it can be vetoed; empty when nothing."
          }
        },
        "required" => ["key", "title", "summary"]
      }
    }
  ]

  @architect_tools [
    %{
      "name" => "save_plan",
      "description" =>
        "Save the implementation plan. The panel shows it as soon as it is saved, so save from the first " <>
          "draft and again after every review comment: each save replaces the plan in full. It must open with " <>
          "the `## Implementation plan` heading.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "plan" => %{"type" => "string", "description" => "The whole plan, in markdown."}
        },
        "required" => ["plan"]
      }
    }
  ]

  @engineer_tools [
    %{
      "name" => "commit",
      "description" =>
        "Hand over finished work. Call it once the work is finished and its tests pass: it ends your turn " <>
          "on the spot, and Rail commits the worktree under your message and pushes it or runs CI. After a CI " <>
          "failure that was not your change's to fix, call it with nothing changed and CI runs again.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "message" => %{
            "type" => "string",
            "description" =>
              "One line saying what this change does, a blank line, then what changed and why, as a commit body."
          }
        },
        "required" => ["message"]
      }
    },
    %{
      "name" => "request_merge",
      "description" =>
        "Ask Rail to merge the default branch into a clean worktree, for example when CI failed on a change " <>
          "that landed there. It ends your turn on the spot. A clean merge is sent on, and conflicts come back " <>
          "to you as a new turn.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }
  ]

  @review_tools [
    %{
      "name" => "save_finding",
      "description" =>
        "Save one finding as soon as you have confirmed it, rather than at the end; the human sees it while " <>
          "you keep reading. A save in the wrong shape is refused naming each field; fix it and save again.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "key" => @finding_key,
          "title" => %{"type" => "string", "description" => "One line naming the problem."},
          "detail" => %{"type" => "string", "description" => "What is wrong and what it costs."},
          "suggestion" => %{"type" => "string", "description" => "The change that settles it."},
          "file" => %{"type" => "string", "description" => "The file it is in, relative to the worktree."},
          "line" => %{"type" => "integer", "description" => "One line number, a positive whole number."},
          "severity" => @severity,
          "recommendation" => @recommendation,
          "status" => @status
        },
        "required" => ["key", "title", "severity", "recommendation"]
      }
    },
    %{
      "name" => "save_review",
      "description" =>
        "Say the review pass is finished, once every finding is saved. Call it last, and call it when you " <>
          "found nothing too: that is a clean review. A pass that ends without it has not reported.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }
  ]

  @qa_report_tools [
    %{
      "name" => "save_finding",
      "description" =>
        "Save one finding as soon as you have reproduced it, with its evidence filed first through qa_shot or " <>
          "qa_file. A finding with no evidence, or citing a file that is not in the QA folder, is refused naming " <>
          "each field; fix it and save again.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "key" => @finding_key,
          "title" => %{"type" => "string", "description" => "One line naming the defect."},
          "check" => %{"type" => "string", "description" => "The key of the checklist row it came out of."},
          "criterion" => %{"type" => "string", "description" => "The acceptance criterion it fails, quoted."},
          "screen" => %{"type" => "string", "description" => "Where it was seen, such as /bills/new."},
          "steps" => %{"type" => "string", "description" => "Numbered steps that reproduce it."},
          "expected" => %{"type" => "string", "description" => "What should have happened."},
          "observed" => %{"type" => "string", "description" => "What happened."},
          "detail" => %{"type" => "string", "description" => "What it costs and who it costs it."},
          "suggestion" => %{"type" => "string", "description" => "The change that settles it."},
          "severity" => @severity,
          "recommendation" => @recommendation,
          "caused_by_change" => %{
            "type" => "boolean",
            "description" => "`false` for something already broken before this branch."
          },
          "status" => @status,
          "evidence" => %{
            "type" => "array",
            "description" => "At least one piece: a name qa_shot or qa_file handed back, or a small value inline.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "name" => %{"type" => "string", "description" => "What it shows."},
                "kind" => %{"type" => "string", "enum" => ["screenshot", "log", "query", "note"]},
                "path" => %{"type" => "string", "description" => "Relative to the QA folder, as Rail named it."},
                "text" => %{"type" => "string", "description" => "Something small enough to read inline."}
              },
              "required" => ["name", "kind"]
            }
          }
        },
        "required" => ["key", "title", "check", "severity", "recommendation", "evidence"]
      }
    },
    %{
      "name" => "save_verdict",
      "description" =>
        "Save the verdict on the whole change, last, once every finding is saved. A pass that ends without " <>
          "it has not reported.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "verdict" => %{
            "type" => "string",
            "enum" => ["pass", "concerns", "fail"],
            "description" => "Your judgement, not a tally of the findings."
          },
          "summary" => %{
            "type" => "string",
            "description" => "One or two sentences: whether it works, and the one thing most in the way if not."
          },
          "not_checked" => %{
            "type" => "string",
            "description" => "What you could not check, and why, including anything you faked or stood in for."
          }
        },
        "required" => ["verdict", "summary"]
      }
    }
  ]

  @demo_report_tools [
    %{
      "name" => "save_demo",
      "description" => "Save the write-up of the recording, once the take is recorded. Saving again replaces it.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "title" => %{"type" => "string", "description" => "What this change lets somebody do, in a few words."},
          "summary" => %{
            "type" => "string",
            "description" => "Two or three sentences: what the change is, and what the walkthrough shows."
          },
          "not_shown" => %{
            "type" => "string",
            "description" => "Anything on the ticket the recording does not cover, and why; empty when nothing."
          }
        },
        "required" => ["title", "summary"]
      }
    }
  ]

  @doc """
  The tools Rail serves this run itself: the browser for the two stages that
  drive one, and the save tools each stage hands its output over with.
  """
  def mcp_tools(%Role{stage: :product}), do: @product_tools
  def mcp_tools(%Role{stage: :design}), do: @design_tools
  def mcp_tools(%Role{stage: :architect}), do: @architect_tools
  def mcp_tools(%Role{stage: :engineer}), do: @engineer_tools
  def mcp_tools(%Role{stage: :review}), do: @review_tools
  def mcp_tools(%Role{stage: :qa}), do: @browser_tools ++ @qa_tools ++ @qa_report_tools
  def mcp_tools(%Role{stage: :demo}), do: @browser_tools ++ @demo_tools ++ @demo_report_tools
  def mcp_tools(%Role{}), do: []
end

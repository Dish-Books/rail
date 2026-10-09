defmodule Rail.Mcp.Utils.McpTools do
  @moduledoc """
  The tools Rail serves itself, and which stage is offered each of them.

  Unlike everything else the proxy serves, these have no upstream, no account and
  nothing forwarded: Rail runs them. This module is only the register - what they
  are called, what they take, and who may call them - and
  `Rail.Mcp.Actions.CallRunTool` is what runs them. A name that is not on a run's
  list is a name to forward, so this is also the gate.

  Three registers, because Review's explorers and its demo recorder drive the
  same browser for different reasons. `@browser_tools` is the browser itself and
  belongs to neither: an explorer drives it to find out whether the change works,
  the recorder drives it to show that it does, and the page does not care which.
  Rail holds it, so it can keep the session alive between calls, film and stream
  it, and take the whole thing down when the task leaves Review. Every other stage
  reads code, and a browser would be a thing to get lost in.

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
  called. The Review lead's subagents inherit its tools, so the one register is
  theirs too: that only the lead saves a finding is its brief's rule.

  `@knowledge_tools` are offered to every role: `knowledge_search` reads the
  rules the project has learned, which no stage should have to guess at.

  `@demo_tools` are about a recording. `demo_start` is the camera, and it is the
  agent's to switch on: a run filmed from its first call to its last is a film of
  an agent working out how the application behaves, which is not the demo. So the
  rehearsal happens off camera and the take is what gets recorded. `demo_say` is
  how the agent narrates what it is about to do, stamped against the recording's
  own clock so the caption is up while the thing happens.
  """

  alias Rail.Roles.Schemas.Role

  @browser %{
    "type" => "string",
    "description" =>
      "Which of your browsers, by the name you gave it in browser_connect, such as `explorer-1` or `demo`; " <>
        "a name it never opened is refused."
  }

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
          "same tab, so the panel and a demo recording show what you do. Each `browser` name is a " <>
          "context and tab of its own; the first call for a name signs it in as a fresh account the " <>
          "project's seed makes for it, when the project has one, and says who. Call it again with the " <>
          "same name if the address stops answering, in a later turn, or after Rail restarts: you get " <>
          "the same tab back, where you left it and signed in as the same account. Only a tab Chrome " <>
          "lost is opened again, and then signed in as a new account.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "browser" => %{
            "type" => "string",
            "description" =>
              "A name for this browser, a few letters, digits, spaces or dashes: the one the lead gave you, such " <>
                "as `explorer-1` or `demo`. Another name is another browser signed in as another account."
          },
          "account" => %{
            "type" => "string",
            "enum" => ["fresh", "bare"],
            "description" =>
              "`fresh`, the default, signs a new browser in as a new account. `bare` opens it with nobody " <>
                "signed in and the seed not run, for checking sign-up, onboarding or billing itself. It " <>
                "only applies to a name's first call: a reconnect keeps whoever the browser already is, so " <>
                "ask for a bare one under a new name."
          }
        }
      }
    },
    %{
      "name" => "browser_problems",
      "description" =>
        "Everything the browser complained about since this was last asked: uncaught exceptions, " <>
          "console errors, failed requests, a crashed page. Draining, so what comes back belongs " <>
          "to whatever just ran. Ask often.",
      "inputSchema" => %{"type" => "object", "properties" => %{"browser" => @browser}}
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
          "name" => %{"type" => "string", "description" => "What this picture shows."},
          "browser" => @browser
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
          "browser" => %{"type" => "string", "description" => "The browser it came from, by its name, if any."},
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
          "went wrong costs a retake rather than a bad video. It films the browser named `browser`.",
      "inputSchema" => %{"type" => "object", "properties" => %{"browser" => @browser}}
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

  @range %{
    "file" => %{"type" => "string", "description" => "Relative to the worktree."},
    "line" => %{"type" => "integer", "description" => "The first line, a positive whole number."},
    "end_line" => %{"type" => "integer", "description" => "The last line, when it spans more than one."}
  }

  @plan_tools [
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
    },
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
    },
    %{
      "name" => "save_plan",
      "description" =>
        "Save the implementation plan. The panel shows it as soon as it is saved, so save from the first " <>
          "draft and again after every review comment: each save replaces the plan in full. It must open with " <>
          "the `## Implementation plan` heading and hold the `###` sections your brief lists, in order; a save " <>
          "whose sections are off is refused with what to fix. Name the design option it is written for; approval needs " <>
          "the plan saved for the option the human picked.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "plan" => %{"type" => "string", "description" => "The whole plan, in markdown."},
          "design" => %{
            "type" => "string",
            "description" =>
              "The key of the saved design option this plan is written for. Leave it out when there are no " <>
                "options, or while the plan leaves the screen open before the pick."
          }
        },
        "required" => ["plan"]
      }
    },
    %{
      "name" => "save_split",
      "description" =>
        "Save a split of the work into child tickets, when it is too big for one. Each save replaces the whole " <>
          "split, so save every child each time, in the order they should run. Every child needs its title, " <>
          "its ticket and its part of the plan, or the save is refused naming the child and the field, and " <>
          "the last good save stays. Save an empty list of children to remove the split.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "children" => %{
            "type" => "array",
            "description" =>
              "Two or more children, in order. Approval makes each a Linear sub-issue with a task of its own.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "title" => %{"type" => "string", "description" => "The child's ticket title, one line."},
                "ticket" => %{
                  "type" => "string",
                  "description" => "The child's ticket body in markdown, with its own acceptance criteria."
                },
                "estimate" => %{"type" => "integer", "description" => "Points, zero or more."},
                "plan" => %{
                  "type" => "string",
                  "description" =>
                    "The part of the plan this child builds, a complete plan in the same sections, opening " <>
                      "with the `## Implementation plan` heading."
                },
                "builds_on" => %{
                  "type" => "array",
                  "items" => %{"type" => "integer"},
                  "description" =>
                    "The numbers of the earlier children, counted from 1, that must merge before this one starts. " <>
                      "Empty when it can start at once."
                }
              },
              "required" => ["title", "ticket", "plan"]
            }
          }
        },
        "required" => ["children"]
      }
    }
  ]

  @engineer_tools [
    %{
      "name" => "commit",
      "description" =>
        "Hand over finished work. Call it once the work is finished and its tests pass: it ends your turn " <>
          "on the spot, and Rail commits the worktree under your message and pushes it or runs CI. Nothing " <>
          "you write after it is read, so write your summary for the human (what you changed, how you " <>
          "checked it, what you could not do) in the same message, before the call. After a CI failure that " <>
          "was not your change's to fix, call it with nothing changed and CI runs again.",
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
          "that landed there. It ends your turn on the spot, so say why in the same message, before the call. A clean merge is sent on, and conflicts come back " <>
          "to you as a new turn.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }
  ]

  @review_lead_tools [
    %{
      "name" => "save_finding",
      "description" =>
        "Save one finding once the round has confirmed it; the human rules on each in Rail. A new key needs " <>
          "everything the finding says, its evidence and every place its rule applies, and a save missing a " <>
          "field, over a limit or holding tool-call markup is refused naming the field: fix it and save again. " <>
          "Saving a known key on a later round takes only its `status`, a `note` and any new `evidence`; what " <>
          "it said when raised never changes.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "key" => %{
            "type" => "string",
            "description" =>
              "Your own name for the problem, lowercase with hyphens, the same for the same problem across rounds."
          },
          "kind" => %{"type" => "string", "enum" => ["code", "screen"], "description" => "In the diff, or on screen."},
          "raised_by" => %{
            "type" => "string",
            "enum" => ["code_reviewer", "explorer", "review_lead"],
            "description" => "Who found it."
          },
          "title" => %{"type" => "string", "description" => "What is wrong, in 90 characters or less."},
          "problem" => %{"type" => "string", "description" => "At most two plain sentences, 300 characters."},
          "file" => @range["file"],
          "line" => @range["line"],
          "end_line" => @range["end_line"],
          "screen" => %{"type" => "string", "description" => "For a screen finding, where it was seen."},
          "steps" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "For a screen finding, the steps that reach it, one each."
          },
          "check" => %{"type" => "string", "description" => "The key of the checklist row it came out of, if any."},
          "fix" => %{
            "type" => "string",
            "description" => "At most two sentences, 300 characters, pointing the way rather than writing the patch."
          },
          "why" => %{"type" => "string", "description" => "Why fix it or leave it, 200 characters."},
          "rule" => %{"type" => "string", "description" => "The rule the change breaks, 160 characters."},
          "places" => %{
            "type" => "array",
            "description" => "Every place the rule applies: a code range with a short label, or a screen with its steps.",
            "items" => %{
              "type" => "object",
              "properties" =>
                Map.merge(@range, %{
                  "label" => %{"type" => "string", "description" => "A few words naming it, 80 characters."},
                  "screen" => %{"type" => "string"},
                  "steps" => %{"type" => "array", "items" => %{"type" => "string"}}
                })
            }
          },
          "evidence" => %{
            "type" => "array",
            "description" =>
              "At least one piece: a `code` range in the worktree, a name qa_shot or qa_file handed back as " <>
                "`path`, or a small value as `text`.",
            "items" => %{
              "type" => "object",
              "properties" =>
                Map.merge(@range, %{
                  "name" => %{"type" => "string", "description" => "What it shows."},
                  "kind" => %{"type" => "string", "enum" => ["code", "screenshot", "log", "query", "note"]},
                  "path" => %{"type" => "string", "description" => "Relative to the QA folder, as Rail named it."},
                  "text" => %{"type" => "string", "description" => "Something small enough to read inline."}
                }),
              "required" => ["name", "kind"]
            }
          },
          "severity" => %{
            "type" => "string",
            "enum" => ["blocker", "major", "minor", "nit"],
            "description" => "How much it matters."
          },
          "recommendation" => %{
            "type" => "string",
            "enum" => ["fix", "skip"],
            "description" => "Whether you would fix it. Your advice; the human decides."
          },
          "checklist_rule" => %{
            "type" => "string",
            "description" =>
              "The id of the checklist rule it comes from; leave it out when it comes from none. A finding a " <>
                "calibration rule says not to raise is still saved, with that rule's id."
          },
          "status" => %{
            "type" => "string",
            "enum" => ["open", "fixed", "not_fixed"],
            "description" => "On a later round, whether a finding raised before is now fixed."
          },
          "note" => %{"type" => "string", "description" => "What this round checked and saw, 300 characters."}
        },
        "required" => ["key"]
      }
    },
    %{
      "name" => "save_review",
      "description" =>
        "Say the round is finished, once every finding is saved and every check settled. Call it last, and " <>
          "call it when the round found nothing too. A round that ends without it has not reported.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "commit_fixes",
      "description" =>
        "Commit the fix round, once the engineer has fixed every finding ruled Fix and the code reviewer has " <>
          "read the diff. It ends your turn on the spot: Rail commits the round as one commit, runs CI and " <>
          "starts the next round once it passes. It refuses a round that leaves a Fix finding out, lists one " <>
          "without a place or a test, or holds a changed file nothing listed explains. After a CI failure, " <>
          "call it with nothing changed and CI runs again.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "message" => %{
            "type" => "string",
            "description" => "One line saying what this round fixes, a blank line, then the body."
          },
          "findings" => %{
            "type" => "array",
            "description" => "Every finding ruled Fix and still to fix.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "key" => %{"type" => "string"},
                "covered" => %{
                  "type" => "array",
                  "items" => %{"type" => "integer"},
                  "description" => "The numbers of the places, from 1, its fix covers."
                },
                "left" => %{
                  "type" => "array",
                  "description" => "The places the fix leaves as they are, and why.",
                  "items" => %{
                    "type" => "object",
                    "properties" => %{"place" => %{"type" => "integer"}, "reason" => %{"type" => "string"}},
                    "required" => ["place", "reason"]
                  }
                },
                "test" => %{
                  "type" => "object",
                  "description" => "The test that failed before the fix.",
                  "properties" => %{"file" => %{"type" => "string"}, "name" => %{"type" => "string"}},
                  "required" => ["file", "name"]
                }
              },
              "required" => ["key", "covered", "test"]
            }
          },
          "other_files" => %{
            "type" => "array",
            "description" => "Every other changed file, with the reason the human reads.",
            "items" => %{
              "type" => "object",
              "properties" => %{"path" => %{"type" => "string"}, "reason" => %{"type" => "string"}},
              "required" => ["path", "reason"]
            }
          }
        },
        "required" => ["message", "findings"]
      }
    }
  ]

  @demo_report_tools [
    %{
      "name" => "save_demo",
      "description" =>
        "Save the write-up of the recording straight after the last beat: it stops the recording and Rail " <>
          "encodes it and publishes the video. Saving again after another take replaces it.",
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

  @knowledge_tools [
    %{
      "name" => "knowledge_search",
      "description" =>
        "Search the rules this project has learned from people's corrections and decisions, nearest " <>
          "first. Search before you ask a question, before you depart from the plan, and before you " <>
          "change a module you do not know: the answer is often already a rule. Describe what you are " <>
          "about to do or decide in a sentence; the search matches meaning, not words.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "What you are about to decide, ask or change."}
        },
        "required" => ["query"]
      }
    }
  ]

  @doc """
  The tools Rail serves this run itself: the browser for the Review lead, whose
  explorers and demo recorder drive one, the save tools each lead hands its
  output over with, and the knowledge base for all.
  """
  def mcp_tools(%Role{stage: :plan}), do: @plan_tools ++ @knowledge_tools
  def mcp_tools(%Role{stage: :engineer}), do: @engineer_tools ++ @knowledge_tools

  def mcp_tools(%Role{stage: :review_lead}),
    do: @browser_tools ++ @qa_tools ++ @demo_tools ++ @review_lead_tools ++ @demo_report_tools ++ @knowledge_tools

  def mcp_tools(%Role{}), do: @knowledge_tools
end

import Ecto.Query

alias Rail.Backends.Schemas.Backend
alias Rail.Projects.Schemas.Project
alias Rail.Repo
alias Rail.Roles.Schemas.Role
alias Rail.Users.Schemas.User

# 1. Admin User
admin_user =
  Repo.get_by(User, email: "admin@rail.local") ||
    Repo.get_by(User, login: "admin") ||
    case Rail.Users.register_oauth_user(%{
           github_id: "1",
           login: "admin",
           name: "Admin",
           email: "admin@rail.local",
           admin: true
         }) do
      {:ok, user} -> user
      user -> user
    end

# 2. Default Project
default_project =
  Repo.get_by(Project, name: "Rail") ||
    Repo.get_by(Project, github_repo: "Rail-AI-dev/rail") ||
    %Project{}
    |> Project.changeset(%{
      name: "Rail",
      github_repo: "Rail-AI-dev/rail",
      github_installation_id: 1,
      default_branch: "main",
      linear_team_id: "rail-team",
      linear_team_key: "RAIL",
      linear_state_ids: %{
        "triage" => "state_triage",
        "backlog" => "state_backlog",
        "in_progress" => "state_in_progress",
        "done" => "state_done",
        "canceled" => "state_canceled"
      },
      clone_path: "/var/rail/worktrees/rail",
      active: true
    })
    |> Repo.insert!()

# 3. CLI Backends — a role cannot exist without the backend it runs on, and the
# path it records is the absolute one the spawner executes.
claude_backend =
  Repo.get_by(Backend, name: :claude) ||
    %Backend{}
    |> Backend.changeset(%{
      name: :claude,
      executable_path: System.find_executable("claude") || "claude"
    })
    |> Repo.insert!()

# 4. Default Roles for Project
default_roles = [
  %{
    stage: :product,
    name: "Product Manager",
    description: "Clarifies problem statements, gathers requirements, and prepares issues for architecture",
    icon_name: "pi-clipboard-text",
    backend_id: claude_backend.id,
    model: "claude-3-7-sonnet",
    reasoning_effort: :high,
    system_prompt:
      "You are an expert Product Manager. Clarify requirements, define scope, and prepare detailed acceptance criteria for the engineering team.",
    max_concurrent: 1,
    position: 0
  },
  %{
    stage: :architect,
    name: "Software Architect",
    description: "Designs technical architecture, file changes, and implementation plans",
    icon_name: "pi-cube",
    backend_id: claude_backend.id,
    model: "claude-3-7-sonnet",
    reasoning_effort: :high,
    system_prompt:
      "You are a Principal Software Architect. Design clean, modular architecture, specify precise component interfaces, and write actionable technical implementation plans.",
    max_concurrent: 1,
    position: 1
  },
  %{
    stage: :design,
    name: "Product Designer",
    description: "Designs user interfaces, layout specs, and UX flows",
    icon_name: "pi-paint-brush",
    backend_id: claude_backend.id,
    model: "claude-3-7-sonnet",
    reasoning_effort: :high,
    system_prompt:
      "You are a Senior Product Designer. Create intuitive user experiences, responsive layouts, and accessible UI specifications.",
    max_concurrent: 1,
    position: 2
  },
  %{
    stage: :engineer,
    name: "Software Engineer",
    description: "Implements vertical slices, writes tests, and adheres to code standards",
    icon_name: "pi-code",
    backend_id: claude_backend.id,
    model: "claude-3-7-sonnet",
    reasoning_effort: :high,
    system_prompt:
      "You are a Staff Software Engineer. Implement features with strict TDD, clean modular code, 100% test coverage, and no lint warnings.",
    max_concurrent: 2,
    position: 3
  },
  %{
    stage: :review,
    name: "Code Reviewer",
    description: "Reviews code changes against quality standards, architecture, and tests",
    icon_name: "pi-eye",
    backend_id: claude_backend.id,
    model: "claude-3-7-sonnet",
    reasoning_effort: :high,
    system_prompt:
      "You are a Principal Code Reviewer. Review git diffs thoroughly for correctness, edge cases, regression risks, style compliance, and security vulnerabilities.",
    max_concurrent: 1,
    position: 4
  },
  %{
    stage: :qa,
    name: "QA Engineer",
    description: "Executes automated test suites and exercises running applications",
    icon_name: "pi-flask",
    backend_id: claude_backend.id,
    model: "claude-3-7-sonnet",
    reasoning_effort: :high,
    system_prompt:
      "You are an expert QA Automation Engineer. Execute test suites, verify user flows against acceptance criteria, and capture reproducible defect reports.",
    max_concurrent: 1,
    position: 5
  },
  %{
    stage: :qa_lead,
    name: "QA Lead",
    description: "Evaluates overall quality gates, reviews QA reports, and grants sign-off",
    icon_name: "pi-shield-check",
    backend_id: claude_backend.id,
    model: "claude-3-7-sonnet",
    reasoning_effort: :high,
    system_prompt:
      "You are the QA Lead. Review test evidence, verify acceptance criteria completeness, evaluate defect severity, and grant release sign-off.",
    max_concurrent: 1,
    position: 6
  },
  %{
    stage: :demo,
    name: "Demo Presenter",
    description: "Generates narrated demonstration walkthroughs of completed features",
    icon_name: "pi-video-camera",
    backend_id: claude_backend.id,
    model: "claude-3-7-sonnet",
    reasoning_effort: :high,
    system_prompt:
      "You are a Demo Presenter. Record comprehensive, narrated end-to-end walkthroughs showcasing feature functionality and verified user journeys.",
    max_concurrent: 1,
    position: 7
  }
]

for role_attrs <- default_roles do
  stage = role_attrs.stage

  if !Repo.exists?(from(r in Role, where: r.project_id == ^default_project.id and r.stage == ^stage)) do
    %Role{}
    |> Role.changeset(role_attrs, default_project.id)
    |> Repo.insert!()
  end
end

{:ok, %{admin_user: admin_user, project: default_project}}

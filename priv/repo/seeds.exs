import Ecto.Query

alias Rail.Projects.Schemas.Project
alias Rail.Repo
alias Rail.Roles.Schemas.Role
alias Rail.Tools.Schemas.Backend
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
      linear_team_key: "RAIL",
      clone_path: "/var/rail/worktrees/rail",
      active: true
    })
    |> Repo.insert!()

# 3. CLI Backends - the account a role's runs are placed on, and the absolute
# path the spawner executes.
_claude_backend =
  Repo.get_by(Backend, name: :claude) ||
    %Backend{}
    |> Backend.changeset(%{
      name: :claude,
      executable_path: System.find_executable("claude") || "claude"
    })
    |> Repo.insert!()

# 4. Default Roles for Project
# What runs is .rail/prompts/<stage>.md on the project's default branch; the copy
# seeded here is only the fallback for when that file is missing or blank. The path
# is relative to the repo, the only place seeds are run from.
read_prompt = &(".rail/prompts/#{&1}.md" |> File.read!() |> String.replace_suffix("\n", ""))

default_roles = [
  # Leads the three below, which run inside its one conversation as subagents on its tools.
  %{
    stage: :plan,
    name: "Plan",
    description: "Leads Product, Designer and Architect to the ticket, the design and the plan",
    icon_name: "pi-compass-tool",
    cli: :claude,
    model: "claude-opus-5-5",
    reasoning_effort: :high,
    system_prompt: read_prompt.("plan"),
    max_concurrent: 1,
    position: 0
  },
  %{
    stage: :product,
    name: "Product Manager",
    description: "Clarifies problem statements, gathers requirements, and prepares issues for architecture",
    icon_name: "pi-clipboard-text",
    cli: :claude,
    model: "claude-opus-5-5",
    reasoning_effort: :high,
    system_prompt: read_prompt.("product"),
    max_concurrent: 1,
    position: 0
  },
  %{
    stage: :design,
    name: "Product Designer",
    description: "Designs user interfaces, layout specs, and UX flows",
    icon_name: "pi-paint-brush",
    cli: :claude,
    model: "claude-opus-5-5",
    reasoning_effort: :high,
    system_prompt: read_prompt.("design"),
    max_concurrent: 1,
    position: 1
  },
  %{
    stage: :architect,
    name: "Software Architect",
    description: "Designs technical architecture, file changes, and implementation plans",
    icon_name: "pi-cube",
    cli: :claude,
    model: "claude-opus-5-5",
    reasoning_effort: :high,
    system_prompt: read_prompt.("architect"),
    max_concurrent: 1,
    position: 2
  },
  %{
    stage: :engineer,
    name: "Software Engineer",
    description: "Implements vertical slices, writes tests, and adheres to code standards",
    icon_name: "pi-code",
    cli: :claude,
    model: "claude-opus-5-5",
    reasoning_effort: :high,
    system_prompt: read_prompt.("engineer"),
    max_concurrent: 2,
    position: 3
  },
  %{
    stage: :review,
    name: "Code Reviewer",
    description: "Reviews code changes against quality standards, architecture, and tests",
    icon_name: "pi-eye",
    cli: :claude,
    model: "claude-opus-5-5",
    reasoning_effort: :high,
    system_prompt: read_prompt.("review"),
    max_concurrent: 1,
    position: 4
  },
  %{
    stage: :qa,
    name: "QA Engineer",
    description: "Executes automated test suites and exercises running applications",
    icon_name: "pi-flask",
    cli: :claude,
    model: "claude-opus-5-5",
    reasoning_effort: :high,
    system_prompt: read_prompt.("qa"),
    max_concurrent: 1,
    position: 5
  },
  %{
    stage: :demo,
    name: "Demo Presenter",
    description: "Records narrated walkthroughs of the finished change in the running application",
    icon_name: "pi-video-camera",
    cli: :claude,
    model: "claude-opus-5-5",
    reasoning_effort: :high,
    system_prompt: read_prompt.("demo"),
    max_concurrent: 1,
    position: 6
  },
  %{
    stage: :triage,
    name: "Triage",
    description: "Reads Slack threads, verifies each claim against the code, and drafts replies and issues",
    icon_name: "pi-magnifying-glass",
    cli: :claude,
    model: "claude-opus-5-5",
    reasoning_effort: :high,
    system_prompt: read_prompt.("triage"),
    max_concurrent: 1,
    position: 7
  },
  %{
    stage: :curator,
    name: "Curator",
    description: "Distills finished tasks into observations and proposes daily how the project's rules should change",
    icon_name: "pi-brain",
    cli: :claude,
    model: "claude-opus-5-5",
    reasoning_effort: :high,
    # Every curator pass carries its whole job in its brief, so the role needs no prompt file.
    system_prompt: "You curate a project's knowledge base for Rail. Each brief says what to read and what to write.",
    max_concurrent: 1,
    position: 8
  }
]

for role_attrs <- default_roles do
  stage = role_attrs.stage

  if !Repo.exists?(from(r in Role, where: r.project_id == ^default_project.id and r.stage == ^stage)) do
    %Role{}
    |> Role.changeset(Map.put(role_attrs, :project_id, default_project.id))
    |> Repo.insert!()
  end
end

{:ok, %{admin_user: admin_user, project: default_project}}

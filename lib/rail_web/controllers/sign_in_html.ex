defmodule RailWeb.SignInHTML do
  @moduledoc false
  use RailWeb, :html

  def index(assigns) do
    ~H"""
    <main
      id="sign-in"
      data-qa="sign-in"
      class="h-full flex flex-col items-center justify-center gap-8 px-6 bg-slate-50 dark:bg-slate-950"
    >
      <div class="flex flex-col items-center text-center max-w-sm">
        <div class="flex items-center justify-center size-14 rounded-2xl bg-blue-50 dark:bg-blue-950 text-blue-600 dark:text-blue-400 ring-1 ring-blue-100 dark:ring-blue-900">
          <.icon name="pi-git-branch" class="size-7" />
        </div>

        <h1 class="mt-5 text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100">
          Rail
        </h1>

        <p class="mt-2 text-sm leading-relaxed text-slate-500 dark:text-slate-400">
          Sign in with the GitHub account your commits should be attributed to.
        </p>
      </div>

      <.button
        variant="primary"
        href={~p"/auth/github"}
        id="sign-in-with-github"
        data-qa="sign_in_with_github"
      >
        <.icon name="pi-github-logo" class="size-4" /> Sign in with GitHub
      </.button>
    </main>
    """
  end
end

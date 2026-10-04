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
          <svg viewBox="0 0 64 64" class="size-14" fill="none" aria-hidden="true" id="sign-in-mark">
            <mask id="sign-in-mark-rails" stroke-linejoin="round">
              <path d="M21 56V17H35a9.5 9.5 0 0 1 0 19H21M32 36 46 57" stroke="#fff" stroke-width="12" />
              <path d="M21 56V17H35a9.5 9.5 0 0 1 0 19H21M32 36 46 57" stroke="#000" stroke-width="4.5" />
            </mask>
            <rect width="64" height="52" fill="currentColor" mask="url(#sign-in-mark-rails)" />
          </svg>
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

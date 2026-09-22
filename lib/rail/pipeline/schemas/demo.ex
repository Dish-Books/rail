defmodule Rail.Pipeline.Schemas.Demo do
  @moduledoc """
  What a demo run says it filmed, as it stands on disk. There is no table behind
  this.

  Nothing rules on a demo the way a human rules on a finding, so there is nothing
  to survive a rewrite: the next recording replaces the last one whole, and a
  task has one demo, the current one. It is read off the file whenever the panel
  draws, the way the QA verdict and the approved design are.

  That does mean a demo is not history. Once the task is cleaned up the video
  goes with the scratch directory, and a merged task can no longer be asked what
  its walkthrough showed.

  The beats are not in here. They are stamped by Rail against the recording's own
  clock while the run is still going, so they are read separately and are there
  even for a run that never got as far as writing this file.
  """

  # A plain struct rather than an embedded schema: nothing casts this, nothing
  # queries it, and the only thing that builds one is the reader.
  defstruct [:title, :summary, :not_shown]
end

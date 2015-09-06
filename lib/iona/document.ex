defmodule Iona.Document do
  defstruct [:source, :source_path, :format, :include, :output_path]

  @type t :: %Iona.Document{}

end

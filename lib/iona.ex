defmodule Iona do
  @moduledoc File.read!("#{__DIR__}/../README.md")

  defmodule UnsupportedFormat do
    defexception message: "No processor defined for format"
  end

  defmodule ProcessingError do
    defexception message: "Could not process the document"
  end

  use Application
  @doc false
  def start(_type, _args) do
    Iona.Supervisor.start_link()
  end

  @nonstopmode "-interaction=nonstopmode"
  @executable_default_args %{
    "latex" => @nonstopmode,
    "pdflatex" => @nonstopmode
  }

  @type tex :: binary
  @type supported_format :: atom

  @type source_opts :: [
    {:path, Path.t},
    {:include, [Path.t]}
  ]

  # Note: The \\ in the example below is escaping to support ExDoc.
  # In the actual LaTeX source, this would be \documentclass
  @doc """
  Define the document source, either as a raw TeX binary or the path to a `.tex` file.

  As raw TeX:

  ```
  Iona.source("\\documentclass[12pt]{article} ...")
  ```

  From a file:

  ```
  Iona.source(path: "/path/to/document.tex")
  ```

  When providing a file path, you can also define additional files needed
  for processing. They will be copied to the temporary directory where processing
  will take place.

  ```elixir
  Iona.source(path: "/path/to/document.tex",
              include: ["/path/to/document.bib",
                        "/path/to/documentclass.sty"])
  ```

  However, when possible, files should be placed in the search path of your TeX
  installation.
  """
  @spec source(criteria :: tex) :: Iona.Document.t
  def source(criteria) when is_binary(criteria) do
    %Iona.Document{source: criteria}
  end
  @spec source(criteria :: source_opts) :: Iona.Document.t
  def source(criteria) when is_list(criteria) do
    %Iona.Document{source_path: Keyword.get(criteria, :path, nil),
                   include: Keyword.get(criteria, :include, []) |> List.wrap}
  end

  @type processor_name :: binary
  @type preprocessor_name :: binary

  @type processing_opts :: [
    {:preprocess, [preprocessor_name]},
    {:processor, processor_name}
  ]

  @doc """
  Generate a formatted document as a string.

  Without processing options:

  ```
  {:ok, pdf_string} = Iona.source(path: "/path/to/document.tex")
                      |> Iona.to(:pdf)
  ```

  With processing options:

  ```
  {:ok, pdf_string} = Iona.source(path: "/path/to/document.tex")
                      |> Iona.to(:pdf, processor: "xetex")
  ```
  """
  @spec to(doc :: Iona.Document.t,
           format :: supported_format,
           opts :: processing_opts) :: {:ok, binary} | {:error, binary}
  def to(doc, format, opts \\ []) do
    case doc |> process(format, opts) do
      {:ok, document} -> document |> read_output_path
      other -> other
    end
  end

  @doc """
  The same as `to/3`, but raises `Iona.ProcessingError` if it fails.
  Returns the document content otherwise.

  ```
  Iona.source(path: "/path/to/document.tex")
  |> Iona.to!(:pdf)
  |> MyModule.do_something_with_pdf_string
  ```

  If writing to a file, see `write/3` and `write/4`, as they are both
  shorter to type and have better performance characteristics.
  """
  @spec to(doc :: Iona.Document.t,
           format :: supported_format,
           opts :: processing_opts) :: binary
  def to!(doc, format, opts \\ []) do
    case to(doc, format, opts) do
      {:ok, result} -> result
      {:error, err} -> raise ProcessingError, message: err
    end
  end

  @doc """
  Generate a formatted document to a file path.

  Without processing options:

  ```
  :ok = Iona.source(path: "/path/to/document.tex")
        |> Iona.write("/path/to/document.pdf")
  ```

  With processing options:

  ```
  :ok = Iona.source(path: "/path/to/document.tex")
        |> Iona.write("/path/to/document.pdf",
                      processor: "xetex")
  ```
  """
  @spec write(doc :: Iona.Document.t, path :: Path.t, opts :: processing_opts) :: {:ok, pos_integer} | {:error, term}
  def write(doc, path, opts \\ []) do
    result = doc |> process(path |> to_format, opts)
    case result do
      {:ok, document} -> File.cp(document.output_path, path)
      other -> other
    end
  end

  @doc """
  The same as `write/3` but raises `Iona.ProcessingError if it fails.

  Without processing options:

  ```
  Iona.source(path: "/path/to/document.tex")
  |> Iona.write!("/path/to/document.pdf")
  ```

  With processing options:

  ```
  Iona.source(path: "/path/to/document.tex")
  |> Iona.write!("/path/to/document.pdf", processor: "xetex")
  ```
  """
  @spec write!(doc :: Iona.Document.t, path :: Path.t, opts :: processing_opts) :: :ok | no_return
  def write!(doc, path, opts \\ []) do
    case write(doc, path, opts) do
      :ok -> :ok
      {:error, err} -> raise ProcessingError, message: err
    end
  end

  @spec to_format(path :: Path.t) :: atom | no_return
  defp to_format(path) do
    format = path |> parse_format
    if supported_format?(format) do
      format
    else
      raise UnsupportedFormat, message: (format |> to_string)
    end
  end

  @spec supported_format?(format :: atom) :: boolean
  defp supported_format?(format) do
    Enum.member?(supported_formats, format)
  end

  @spec parse_format(path :: Path.t) :: nil | atom
  defp parse_format(path) do
    case Path.extname(path) do
      "" -> nil
      ext -> ext |> String.replace(~r/^\./, "") |> String.to_atom
    end
  end

  @spec supported_formats :: [supported_format]
  defp supported_formats do
    Iona.Config.processors |> Keyword.keys
  end

  @doc false
  @spec process(doc :: Iona.Document.t, format :: atom, opts :: processing_opts) :: {:ok, Iona.Document.t} | {:error, binary}
  def process(%{source: source} = doc, format, opts) when is_binary(source) do
    with_temp fn directory ->
      path = Path.join(directory, "document.tex")
      case File.write(path, source) do
        :ok -> do_process(doc, format, opts, path)
        _ -> {:error, "Could not write to temporary file at path: #{path}"}
      end
    end
  end
  def process(%{source_path: source_path} = doc, format, opts) when is_binary(source_path) do
    with_temp fn directory ->
      path = Path.join(directory, Path.basename(source_path))
      case File.cp(source_path, path) do
        :ok -> do_process(doc, format, opts, path)
        _ -> {:error, "Could not copy source file at path #{source_path} to temporary file at path: #{path}"}
      end
    end
  end
  def process(_doc, _format, _opts) do
    {:error, "No :source or :source_path provided"}
  end

  @spec read_output_path(doc :: Iona.Document.t) :: {:ok, binary} | {:error, binary}
  defp read_output_path(doc) do
    case File.read(doc.output_path) do
      {:error, _} -> {:error, "Could not read generated document at path: " <> doc.output_path}
      other -> other
    end
  end

  @spec do_process(doc :: Iona.Document.t,
                   format :: supported_format,
                   opts :: processing_opts,
                   path :: Path.t) :: {:ok, Iona.Document.t} | {:error, binary}
  defp do_process(doc, format, opts, path) do
    processor = Keyword.get(opts, :processor, Keyword.get(Iona.Config.processors, format, nil))
    if processor do
      output_path = String.replace(path, ~r/\.tex$/, ".#{format}")
      basename = Path.basename(path, ".tex")
      dirname = Path.dirname(path)
      preprocessors = Keyword.get(opts, :preprocess, Iona.Config.preprocess)
      case copy_includes(dirname, doc.include |> List.wrap) do
        :ok ->
          case preprocess(basename, dirname, preprocessors) do
            :ok ->
              case Porcelain.exec(processor,
                                  executable_default_args(processor) ++ [basename],
                                  dir: dirname, out: :string) do
                %{status: 0} -> {:ok, %{doc | output_path: output_path}}
                failure -> {:error, "Processing failed with output: #{failure.out}"}
              end
            err -> err
          end
        other -> other
      end
    else
      {:error, "Could not find processor for format: #{format}"}
    end
  end

  @spec preprocess(name :: binary, dir :: Path.t, preprocessors :: [preprocessor_name]) :: :ok | {:error, binary}
  defp preprocess(_name, _dir, []), do: :ok
  defp preprocess(name, dir, [preprocessor|remaining]) do
    case Porcelain.exec(preprocessor,
                        executable_default_args(preprocessor) ++ [name],
                        dir: dir, out: :string) do
      %{status: 0} -> preprocess(name, dir, remaining)
      failure -> {:error, "Preprocessing with #{preprocessor} failed with output: #{failure.out}"}
    end
  end

  defp copy_includes(_directory, []), do: :ok
  defp copy_includes(directory, [include|remaining]) do
    case File.cp(include, Path.join(directory, Path.basename(include))) do
      :ok -> copy_includes(directory, remaining)
       _ -> {:error, "Could not copy included file: #{include}"}
    end
  end

  defp with_temp(fun) do
    case Briefly.create(prefix: "iona", directory: true) do
      {:ok, path} -> fun.(path)
      _ -> {:error, "Could not create temporary location"}
    end
  end

  defp executable_default_args(name) do
    Map.get(@executable_default_args, name, [])
    |> List.wrap
  end

end

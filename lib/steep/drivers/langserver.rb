module Steep
  module Drivers
    class Langserver
      attr_reader :source_dirs
      attr_reader :signature_dirs
      attr_reader :options
      attr_reader :subscribers

      include Utils::EachSignature

      def initialize(source_dirs:, signature_dirs:)
        @source_dirs = source_dirs
        @signature_dirs = signature_dirs
        @options = Project::Options.new
        @subscribers = {}

        subscribe :initialize do |request:, notifier:|
          LanguageServer::Protocol::Interface::InitializeResult.new(
            capabilities: LanguageServer::Protocol::Interface::ServerCapabilities.new(
              text_document_sync: LanguageServer::Protocol::Interface::TextDocumentSyncOptions.new(
                open_close: true,
                change: LanguageServer::Protocol::Constant::TextDocumentSyncKind::FULL,
              ),
            ),
          )
        end

        subscribe :shutdown do |request:, notifier:|
          Steep.logger.warn "Shutting down the server..."
          exit
        end

        subscribe :"textDocument/didOpen" do |request:, notifier:|
          uri = URI.parse(request[:params][:textDocument][:uri])
          text = request[:params][:textDocument][:text]
          synchronize_project(uri: uri, text: text, notifier: notifier)
        end

        subscribe :"textDocument/didChange" do |request:, notifier:|
          uri = URI.parse(request[:params][:textDocument][:uri])
          text = request[:params][:contentChanges][0][:text]
          synchronize_project(uri: uri, text: text, notifier: notifier)
        end
      end

      def subscribe(method, &callback)
        @subscribers[method] = callback
      end

      def project
        @project ||= Project.new.tap do |project|
          source_dirs.each do |path|
            each_file_in_path(".rb", path) do |file_path|
              file = Project::SourceFile.new(path: file_path, options: options)
              file.content = file_path.read
              project.source_files[file_path] = file
            end
          end

          signature_dirs.each do |path|
            each_file_in_path(".rbi", path) do |file_path|
              file = Project::SignatureFile.new(path: file_path)
              file.content = file_path.read
              project.signature_files[file_path] = file
            end
          end
        end
      end

      def run
        writer = LanguageServer::Protocol::Transport::Stdio::Writer.new
        reader = LanguageServer::Protocol::Transport::Stdio::Reader.new
        notifier = Proc.new { |method:, params: {}| writer.write(method: method, params: params) }

        reader.read do |request|
          id = request[:id]
          method = request[:method].to_sym
          Steep.logger.warn "Received event: #{method}"
          subscriber = subscribers[method]
          if subscriber
            result = subscriber.call(request: request, notifier: notifier)
            if id
              writer.write(id: id, result: result)
            end
          else
            Steep.logger.warn "Ignored event: #{method}"
          end
        end
      end

      def synchronize_project(uri:, text:, notifier:)
        path = Pathname(uri.path).relative_path_from(Pathname.pwd)

        case path.extname
        when ".rb"
          file = project.source_files[path] || Project::SourceFile.new(path: path, options: options)
          file.content = text
          project.source_files[path] = file
          project.type_check

          diags = (file.errors || []).map do |error|
            LanguageServer::Protocol::Interface::Diagnostic.new(
              message: error.to_s,
              severity: LanguageServer::Protocol::Constant::DiagnosticSeverity::ERROR,
              range: LanguageServer::Protocol::Interface::Range.new(
                start: LanguageServer::Protocol::Interface::Position.new(
                  line: error.node.loc.line - 1,
                  character: error.node.loc.column,
                ),
                end: LanguageServer::Protocol::Interface::Position.new(
                  line: error.node.loc.last_line - 1,
                  character: error.node.loc.last_column,
                ),
              )
            )
          end

          notifier.call(
            method: :"textDocument/publishDiagnostics",
            params: LanguageServer::Protocol::Interface::PublishDiagnosticsParams.new(
              uri: uri,
              diagnostics: diags,
            ),
          )
        when ".rbi"
          file = project.signature_files[path] || Project::SignatureFile.new(path: path)
          file.content = text
          project.signature_files[path] = file
          project.type_check
        end
      end
    end
  end
end

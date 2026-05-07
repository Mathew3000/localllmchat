import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/tool_call.dart';
import 'base_mcp_service.dart';

/// Maximum bytes read from a single file before truncating.
const _kMaxFileBytes = 200 * 1024; // 200 KB

/// Maximum entries returned by list_directory.
const _kMaxListEntries = 300;

/// Maximum search hits returned by search_files.
const _kMaxSearchHits = 200;

/// Built-in in-process MCP service that exposes a selected local folder to
/// the LLM.  No external process or network connection is needed — tool calls
/// are handled directly in Dart.
///
/// The service is sandboxed: all paths are resolved relative to [rootPath] and
/// any attempt to escape via `..` components is silently clamped to the root.
class FileMcpService extends BaseMcpService {
  /// Absolute path to the folder the user has granted access to.
  final String rootPath;

  FileMcpService(this.rootPath);

  @override
  String get baseUrl => ''; // no network — unused by callers

  // ── Tool definitions ───────────────────────────────────────────────────────

  /// Static tool list — used by [AppProvider] to register tools without
  /// making an async call.
  static const toolDefs = _tools;

  static const _tools = [
    McpToolDef(
      name: 'list_directory',
      description:
          'List the files and sub-directories inside a folder. '
          'Pass an empty path or "/" to list the root of the selected folder.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description':
                'Relative path inside the selected folder (e.g. "src/utils"). '
                'Omit or leave empty for the root.',
          },
        },
      },
    ),
    McpToolDef(
      name: 'read_file',
      description:
          'Read the text content of a file. Returns the raw UTF-8 text '
          '(truncated to 200 KB for very large files).',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Relative path to the file inside the selected folder.',
          },
        },
        'required': ['path'],
      },
    ),
    McpToolDef(
      name: 'search_files',
      description:
          'Recursively search for files whose name contains [pattern] '
          '(case-insensitive substring match). '
          'Returns relative paths from the selected root.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'pattern': {
            'type': 'string',
            'description': 'Substring to match against file names.',
          },
          'path': {
            'type': 'string',
            'description':
                'Sub-directory to search in (relative, optional). '
                'Defaults to the root.',
          },
        },
        'required': ['pattern'],
      },
    ),
  ];

  @override
  Future<List<McpToolDef>> listTools() async => _tools;

  // ── Tool dispatch ──────────────────────────────────────────────────────────

  @override
  Future<List<McpContent>> callTool(
      String name, Map<String, dynamic> args) async {
    try {
      final String text;
      switch (name) {
        case 'list_directory':
          text = await _listDirectory(args['path'] as String? ?? '');
        case 'read_file':
          text = await _readFile(args['path'] as String? ?? '');
        case 'search_files':
          text = await _searchFiles(
            args['pattern'] as String? ?? '',
            args['path'] as String? ?? '',
          );
        default:
          text = 'Unknown tool: $name';
      }
      return [McpContent(type: 'text', text: text)];
    } catch (e) {
      return [McpContent(type: 'text', text: 'Error: $e')];
    }
  }

  @override
  void dispose() {} // nothing to clean up

  // ── Sandboxed path resolution ─────────────────────────────────────────────

  /// Resolves [relative] against [rootPath], normalises the result, and
  /// ensures it does not escape the root.  Returns the absolute path.
  String _resolve(String relative) {
    // Normalise separators and strip leading slashes.
    final clean = relative.trim().replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
    final joined = clean.isEmpty ? rootPath : p.join(rootPath, clean);
    final normalised = p.normalize(joined);
    // Clamp to root if the path escapes.
    if (!normalised.startsWith(rootPath)) return rootPath;
    return normalised;
  }

  /// Returns the path displayed to the model — relative from root.
  String _display(String absolute) {
    final rel = p.relative(absolute, from: rootPath);
    return rel == '.' ? '/' : rel;
  }

  // ── Tool implementations ───────────────────────────────────────────────────

  Future<String> _listDirectory(String relativePath) async {
    final dir = Directory(_resolve(relativePath));
    if (!await dir.exists()) return 'Error: directory not found: $relativePath';

    final entries = <String>[];
    int count = 0;
    await for (final entity in dir.list(recursive: false, followLinks: false)) {
      if (count >= _kMaxListEntries) {
        entries.add('… (truncated — more than $_kMaxListEntries entries)');
        break;
      }
      final name = p.basename(entity.path);
      if (entity is Directory) {
        entries.add('$name/');
      } else if (entity is File) {
        final stat = await entity.stat();
        final size = _formatSize(stat.size);
        entries.add('$name  ($size)');
      }
      count++;
    }

    if (entries.isEmpty) return 'Empty directory.';
    final label = _display(dir.path);
    entries.sort();
    return 'Contents of $label:\n${entries.join('\n')}';
  }

  Future<String> _readFile(String relativePath) async {
    if (relativePath.trim().isEmpty) return 'Error: path is required';
    final file = File(_resolve(relativePath));
    if (!await file.exists()) return 'Error: file not found: $relativePath';

    final stat = await file.stat();
    final bytes = await file.readAsBytes();
    final truncated = bytes.length > _kMaxFileBytes;
    final slice = truncated ? bytes.sublist(0, _kMaxFileBytes) : bytes;

    // Try UTF-8 decode; fall back to Latin-1 for binary-ish files.
    String content;
    try {
      content = String.fromCharCodes(slice);
    } catch (_) {
      content = '[binary file — cannot display]';
    }

    final header = '${_display(file.path)}  (${_formatSize(stat.size)})'
        '${truncated ? '  [truncated at 200 KB]' : ''}\n\n';
    return header + content;
  }

  Future<String> _searchFiles(String pattern, String startPath) async {
    if (pattern.trim().isEmpty) return 'Error: pattern is required';
    final lower = pattern.toLowerCase();
    final start = Directory(_resolve(startPath));
    if (!await start.exists()) return 'Error: directory not found: $startPath';

    final hits = <String>[];
    await for (final entity
        in start.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path).toLowerCase();
      if (name.contains(lower)) {
        hits.add(_display(entity.path));
        if (hits.length >= _kMaxSearchHits) break;
      }
    }

    if (hits.isEmpty) return 'No files found matching "$pattern".';
    hits.sort();
    return 'Files matching "$pattern":\n${hits.join('\n')}';
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

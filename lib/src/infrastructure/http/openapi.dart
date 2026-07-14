import '../../version.dart';

/// Returns the static OpenAPI 3.0 document describing the v1 HTTP API.
///
/// Generated from the route table so the published contract stays aligned with
/// the implemented endpoints; served at `/api/v1/openapi.json`.
Map<String, dynamic> openApiDocument() => {
  'openapi': '3.0.3',
  'info': {
    'title': 'OmnyServer Hub API',
    'version': omnyServerVersion,
    'description':
        'REST API for the OmnyServer Hub: nodes, status, capabilities, '
        'operations and presets.',
  },
  'servers': [
    {'url': '/api/v1'},
  ],
  'paths': {
    '/whoami': {
      'get': {
        'summary':
            'The identity and roles the Hub resolves your credentials to',
        'responses': {'200': _ok('{principal, roles, authenticated}')},
      },
    },
    '/nodes': {
      'get': {
        'summary': 'List all registered nodes',
        'responses': {'200': _ok('Array of node descriptors')},
      },
    },
    '/nodes/{id}': {
      'get': {
        'summary': 'Get a node descriptor',
        'parameters': [_pathId],
        'responses': {'200': _ok('Node descriptor'), '404': _err},
      },
    },
    '/nodes/{id}/status': {
      'get': {
        'summary': 'Get a node live status snapshot',
        'parameters': [_pathId],
        'responses': {'200': _ok('Node status'), '404': _err},
      },
    },
    '/nodes/{id}/capabilities': {
      'get': {
        'summary': 'Get a node advertised capabilities',
        'parameters': [_pathId],
        'responses': {'200': _ok('Node capabilities'), '404': _err},
      },
    },
    '/nodes/{id}/restart': {
      'post': {
        'summary': 'Restart a node',
        'parameters': [_pathId],
        'responses': {'200': _ok('Accepted'), '404': _err, '502': _err},
      },
    },
    '/nodes/{id}/shutdown': {
      'post': {
        'summary': 'Shut down a node',
        'parameters': [_pathId],
        'responses': {'200': _ok('Accepted'), '404': _err, '502': _err},
      },
    },
    '/nodes/{id}/update': {
      'post': {
        'summary': 'Trigger a node update',
        'parameters': [_pathId],
        'requestBody': _jsonBody({'target': 'string'}),
        'responses': {'200': _ok('Accepted'), '404': _err, '502': _err},
      },
    },
    '/nodes/{id}/formula': {
      'post': {
        'summary': 'Run a formula action on a node',
        'parameters': [_pathId],
        'requestBody': _jsonBody({
          'formula': 'string',
          'action': 'string',
          'version': 'string',
        }),
        'responses': {
          '200': _ok('Formula run result'),
          '400': _err,
          '404': _err,
          '502': _err,
        },
      },
    },
    '/presets/apply': {
      'post': {
        'summary': 'Apply a preset to a node',
        'requestBody': _jsonBody({'nodeId': 'string', 'preset': 'object'}),
        'responses': {'200': _ok('Apply result'), '404': _err, '502': _err},
      },
    },
    '/nodes/{id}/metrics': {
      'get': {
        'summary': "A node's resource history, for charting",
        'parameters': [
          _pathId,
          {
            'name': 'since',
            'in': 'query',
            'description':
                'Window back from now (30s, 15m, 1h, 7d) or an '
                'ISO-8601 instant',
            'schema': {'type': 'string'},
          },
          {
            'name': 'limit',
            'in': 'query',
            'description': 'Maximum samples (default 100)',
            'schema': {'type': 'integer'},
          },
        ],
        'responses': {
          '200': _ok('Array of metric points, newest first'),
          '400': _err,
          '404': _err,
        },
      },
    },
    '/nodes/{id}/desired-state': {
      'get': {
        'summary': 'What a node is declared to be',
        'parameters': [_pathId],
        'responses': {'200': _ok('{steps: [...]}'), '404': _err},
      },
      'put': {
        'summary': 'Declare what a node should be — runs nothing',
        'parameters': [_pathId],
        'requestBody': _jsonBody({'preset': 'object', 'steps': 'array'}),
        'responses': {'200': _ok('Declared'), '404': _err},
      },
      'delete': {
        'summary': 'Stop expecting anything of a node',
        'parameters': [_pathId],
        'responses': {'200': _ok('Cleared'), '404': _err},
      },
    },
    '/nodes/{id}/drift': {
      'get': {
        'summary':
            'How far a node has drifted from what it was declared to be '
            '(plans; runs nothing)',
        'parameters': [_pathId],
        'responses': {'200': _ok('{converged, actions, notes}'), '404': _err},
      },
    },
    '/nodes/{id}/reconcile': {
      'post': {
        'summary':
            'Run whatever the drift plan says is outstanding (idempotent)',
        'parameters': [_pathId],
        'responses': {'200': _ok('Apply result'), '404': _err, '502': _err},
      },
    },
    '/grants': {
      'get': {
        'summary': 'Issued credentials (hashes, never tokens) — admin only',
        'responses': {'200': _ok('Array of grants'), '403': _err},
      },
      'post': {
        'summary':
            'Issue a credential — admin only. The token is returned once and '
            'cannot be read back.',
        'requestBody': _jsonBody({
          'principal': 'string',
          'roles': 'array',
          'note': 'string',
        }),
        'responses': {
          '200': _ok('The grant, and its token'),
          '400': _err,
          '403': _err,
        },
      },
    },
    '/grants/{id}': {
      'delete': {
        'summary': 'Revoke a credential — admin only',
        'parameters': [_pathId],
        'responses': {'200': _ok('Revoked'), '403': _err, '404': _err},
      },
    },
    '/events': {
      'get': {
        'summary': 'Recent Hub events',
        'responses': {'200': _ok('Array of events')},
      },
    },
    '/events/stream': {
      'get': {
        'summary': 'Every event as it happens (text/event-stream)',
        'responses': {'200': _ok('A Server-Sent Events stream')},
      },
    },
    '/audit': {
      'get': {
        'summary': 'Recent audit entries',
        'responses': {'200': _ok('Array of audit entries')},
      },
    },
  },
};

const Map<String, dynamic> _pathId = {
  'name': 'id',
  'in': 'path',
  'required': true,
  'schema': {'type': 'string'},
};

Map<String, dynamic> _ok(String description) => {'description': description};

const Map<String, dynamic> _err = {'description': 'Structured error'};

Map<String, dynamic> _jsonBody(Map<String, String> fields) => {
  'required': true,
  'content': {
    'application/json': {
      'schema': {
        'type': 'object',
        'properties': {
          for (final entry in fields.entries) entry.key: {'type': entry.value},
        },
      },
    },
  },
};

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
    '/events': {
      'get': {
        'summary': 'Recent Hub events',
        'responses': {'200': _ok('Array of events')},
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

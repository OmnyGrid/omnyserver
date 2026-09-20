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
        'summary': 'Restart the agent on a node',
        'description':
            'Restarts the OmnyServer agent, not the machine it runs on. The '
            'agent stops and its supervisor starts it again, so the node goes '
            'offline briefly and comes back on its own.',
        'parameters': [_pathId],
        'responses': {'200': _ok('Accepted'), '404': _err, '502': _err},
      },
    },
    '/nodes/{id}/shutdown': {
      'post': {
        'summary': 'Stop the agent on a node',
        'description':
            'Stops the OmnyServer agent, not the machine it runs on. The node '
            'goes offline and stays offline until something starts the agent '
            'again.',
        'parameters': [_pathId],
        'responses': {'200': _ok('Accepted'), '404': _err, '502': _err},
      },
    },
    '/nodes/{id}/update': {
      'post': {
        'summary': 'Update software the agent manages',
        'description':
            'Applies an update on the node: the OS packages, a single named '
            'package, or the agent itself — chosen with `target`.',
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
    '/nodes/{id}/formulas': {
      'get': {
        'summary': 'What state each of a node\'s formulas is in',
        'description':
            'Asked of the node, not answered from the Hub\'s records: each '
            'formula probes what it manages and reports `absent`, `installed`, '
            '`running`, `stopped`, `failed` or `unknown`. `?formulas=a,b` '
            'narrows it to those ids; the default is everything the node '
            'carries.',
        'parameters': [_pathId],
        'responses': {
          '200': _ok('Array of formula status reports'),
          '404': _err,
          '502': _err,
        },
      },
    },
    '/formulas': {
      'get': {
        'summary':
            'The formulas a node can run, and the actions each implements',
        'responses': {'200': _ok('Array of formula specs')},
      },
    },
    '/blueprints': {
      'get': {
        'summary': 'The blueprints saved on the Hub',
        'responses': {'200': _ok('Array of blueprints')},
      },
      'post': {
        'summary': 'Save a blueprint on the Hub',
        'description':
            'Resolved before it is stored, so a dependency cycle, an '
            'undeclared variable or an include naming a preset nobody saved '
            'comes back as a 400 rather than as a failure half way through an '
            'apply on a real machine.',
        'requestBody': _jsonBody({
          'blueprint': 'string',
          'name': 'string',
          'description': 'string',
        }),
        'responses': {'200': _ok('Saved'), '400': _err},
      },
    },
    '/blueprints/{id}': {
      'get': {
        'summary': 'One blueprint, as it was authored',
        'parameters': [_pathId],
        'responses': {'200': _ok('Blueprint'), '404': _err},
      },
      'delete': {
        'summary': 'Delete a blueprint',
        'parameters': [_pathId],
        'responses': {'200': _ok('Deleted'), '404': _err},
      },
    },
    '/blueprints/{id}/resolved': {
      'get': {
        'summary': 'A blueprint flattened: what a node is actually sent',
        'description':
            'Includes expanded, variables substituted, resources in the order '
            'they would be settled, and a hash over all of it. Every resource '
            'names where it came from and what it overrode.',
        'parameters': [_pathId],
        'responses': {'200': _ok('Resolved blueprint'), '404': _err},
      },
    },
    '/presets': {
      'get': {
        'summary': 'The presets saved on the Hub',
        'responses': {'200': _ok('Array of presets')},
      },
      'post': {
        'summary': 'Save a preset on the Hub',
        'requestBody': _jsonBody({
          'id': 'string',
          'name': 'string',
          'steps': 'array',
        }),
        'responses': {'200': _ok('Saved'), '400': _err, '403': _err},
      },
    },
    '/presets/{id}': {
      'get': {
        'summary': 'A saved preset',
        'parameters': [_pathId],
        'responses': {'200': _ok('Preset'), '404': _err},
      },
      'delete': {
        'summary': 'Delete a saved preset',
        'parameters': [_pathId],
        'responses': {'200': _ok('Deleted'), '403': _err, '404': _err},
      },
    },
    '/presets/apply': {
      'post': {
        'summary':
            'Apply a preset to a node — one sent inline, or a saved one by '
            'presetId',
        'requestBody': _jsonBody({
          'nodeId': 'string',
          'preset': 'object',
          'presetId': 'string',
        }),
        'responses': {
          '200': _ok('Apply result'),
          '400': _err,
          '404': _err,
          '502': _err,
        },
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
    '/nodes/{id}/logs': {
      'get': {
        'summary':
            "The tail of what a node has reported (bounded, in memory — not a "
            'log server)',
        'parameters': [
          _pathId,
          {
            'name': 'tail',
            'in': 'query',
            'description': 'How many lines (default 200)',
            'schema': {'type': 'integer'},
          },
        ],
        'responses': {'200': _ok('Array of log lines'), '404': _err},
      },
    },
    '/nodes/{id}/logs/stream': {
      'get': {
        'summary': "A node's log as it happens (text/event-stream)",
        'parameters': [_pathId],
        'responses': {'200': _ok('A Server-Sent Events stream')},
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
        'description':
            'Three forms: `blueprint` names a saved blueprint (the one to '
            'reach for — it composes shared presets and declares states rather '
            'than actions), `preset` sends one inline, or `steps` sends a bare '
            'step list.',
        'parameters': [_pathId],
        'requestBody': _jsonBody({
          'blueprint': 'string',
          'preset': 'object',
          'steps': 'array',
        }),
        'responses': {'200': _ok('Declared'), '404': _err},
      },
      'delete': {
        'summary': 'Stop expecting anything of a node',
        'parameters': [_pathId],
        'responses': {'200': _ok('Cleared'), '404': _err},
      },
    },
    '/nodes/{id}/unassign': {
      'post': {
        'summary': 'Take the blueprint off a node, removing what it installed',
        'description':
            'Sends an empty blueprint first, so every resource the node\'s '
            'ledger holds is removed. Resources the machine already had are '
            'released rather than removed unless `purgeAdopted`. The node must '
            'be online; a partial failure answers 200 with `success: false` '
            'and leaves the blueprint assigned so it can be retried. To forget '
            'a node that is gone without touching it, DELETE its '
            'desired-state instead.',
        'parameters': [_pathId],
        'requestBody': _jsonBody({
          'purgeAdopted': 'boolean',
          'async': 'boolean',
        }),
        'responses': {
          '200': _ok('Apply result'),
          '202': _ok('Operation handle (async)'),
          '404': _err,
          '502': _err,
        },
      },
    },
    '/nodes/{id}/drift': {
      'get': {
        'summary':
            'How far a node has drifted from what it was declared to be '
            '(plans; runs nothing)',
        'description':
            'A node assigned a blueprint is asked directly — the Hub resolves '
            'and the node reads its own resources, answering in `changes`. A '
            'node declared by steps is planned Hub-side from its advertised '
            'capabilities, answering in `actions`; that costs nothing and works '
            'while the node is offline.',
        'parameters': [_pathId],
        'responses': {
          '200': _ok(
            '{converged, actions | changes, blueprint?, appliedHash?, '
            'expectedHash?, notes}',
          ),
          '404': _err,
          '502': _err,
        },
      },
    },
    '/nodes/{id}/reconcile': {
      'post': {
        'summary':
            'Run whatever the drift plan says is outstanding (idempotent)',
        'description':
            'Applies the assigned blueprint, or runs the outstanding preset '
            'steps. `dryRun` plans without changing anything; `async` hands '
            'back an operation handle instead of waiting.',
        'parameters': [_pathId],
        'requestBody': _jsonBody({
          'dryRun': 'boolean',
          'purgeAdopted': 'boolean',
          'async': 'boolean',
        }),
        'responses': {
          '200': _ok('Apply result'),
          '202': _ok('Operation handle (async)'),
          '404': _err,
          '502': _err,
        },
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
    '/operations': {
      'get': {
        'summary': 'Operations in flight, and the last few that finished',
        'parameters': [
          {
            'name': 'node',
            'in': 'query',
            'schema': {'type': 'string'},
          },
          {
            'name': 'running',
            'in': 'query',
            'schema': {'type': 'boolean'},
          },
        ],
        'responses': {'200': _ok('Array of operations')},
      },
    },
    '/operations/{id}': {
      'get': {
        'summary': 'An operation, and what it produced',
        'parameters': [_pathId],
        'responses': {'200': _ok('Operation'), '404': _err},
      },
    },
    '/alerts': {
      'get': {
        'summary':
            'What is wrong right now (only what is currently breached; the '
            'history is on the event stream)',
        'responses': {'200': _ok('Array of active alerts')},
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

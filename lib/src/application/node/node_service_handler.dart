import '../../infrastructure/service/service_controller.dart';
import '../../protocol/control_message.dart';

/// Answers Hub `ServiceControl` requests on the node by driving a
/// [ServiceController] (systemd / launchd / Windows Service Manager).
///
/// Provides a `ServiceHandler` for the agent config.
class NodeServiceHandler {
  /// The OS service controller.
  final ServiceController controller;

  /// Creates a service handler over [controller].
  const NodeServiceHandler(this.controller);

  /// Handles a [request], returning a result message.
  Future<ServiceControlResult> handle(ServiceControl request) async {
    try {
      switch (request.action) {
        case 'install':
          await controller.install(request.service);
        case 'start':
          await controller.start(request.service);
        case 'stop':
          await controller.stop(request.service);
        case 'restart':
          await controller.restart(request.service);
        case 'uninstall':
          await controller.uninstall(request.service);
        default:
          return ServiceControlResult(
            requestId: request.requestId,
            success: false,
            message: 'unknown service action "${request.action}"',
          );
      }
      final descriptor = await controller.describe(request.service);
      return ServiceControlResult(
        requestId: request.requestId,
        success: true,
        descriptor: descriptor,
      );
    } on Object catch (e) {
      return ServiceControlResult(
        requestId: request.requestId,
        success: false,
        message: 'service ${request.action} failed: $e',
      );
    }
  }
}

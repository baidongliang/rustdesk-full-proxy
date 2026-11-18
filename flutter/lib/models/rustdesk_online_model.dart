import 'platform_model.dart';

typedef OnlineStatusEvent = void Function(Map<String, dynamic> event);

abstract class RustDeskOnlineRepository {
  void subscribe(OnlineStatusEvent onEvent);
  void unsubscribe();
  Future<void> query(List<String> ids);
}

class RustDeskOnlineClient implements RustDeskOnlineRepository {
  static int _nextListenerId = 0;
  static const _eventName = 'callback_query_onlines';

  final String _listenerName = 'school-device-${_nextListenerId++}';

  @override
  void subscribe(OnlineStatusEvent onEvent) {
    platformFFI.registerEventHandler(_eventName, _listenerName, (event) async {
      onEvent(event);
    });
  }

  @override
  void unsubscribe() {
    platformFFI.unregisterEventHandler(_eventName, _listenerName);
  }

  @override
  Future<void> query(List<String> ids) => bind.queryOnlines(ids: ids);
}

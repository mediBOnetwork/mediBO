// Native fallback for the web service-worker bridge. Android clears its own
// tray through the method channel (OrderAlertService.clearNotification), so
// there is nothing for this to do.
void webClearOrderNotification(String orderId) {}

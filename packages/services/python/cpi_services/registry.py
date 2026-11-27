import threading

from .errors import ServiceError


class Registry:
    def __init__(self, services=()):
        self._lock = threading.Lock()
        self._endpoints = {}
        for service in services:
            self.add(service)

    @property
    def endpoints(self):
        with self._lock:
            return tuple(self._endpoints)

    def add(self, service):
        names = tuple(service.endpoints)
        with self._lock:
            if len(set(names)) != len(names) or any(
                name in self._endpoints for name in names
            ):
                raise ValueError("Duplicate service endpoint")
            self._endpoints.update((name, service) for name in names)

    def remove(self, service):
        with self._lock:
            self._endpoints = {
                name: owner
                for name, owner in self._endpoints.items()
                if owner is not service
            }

    def dispatch(self, endpoint, arguments, token, idempotency_key=""):
        with self._lock:
            service = self._endpoints.get(endpoint)
        if service is None:
            raise ServiceError("unsupported_method", "Service endpoint is unavailable")
        return service.dispatch(endpoint, arguments, token, idempotency_key)

    def close(self):
        with self._lock:
            services = tuple({id(s): s for s in self._endpoints.values()}.values())
            self._endpoints.clear()
        failure = None
        for service in services:
            try:
                service.close()
            except Exception as error:
                failure = failure or error
        if failure is not None:
            raise failure

    def poll_events(self):
        with self._lock:
            services = tuple({id(s): s for s in self._endpoints.values()}.values())
        return [
            event
            for service in services
            if hasattr(service, "poll_events")
            for event in service.poll_events()
        ]

import importlib


_PROVIDERS = {
    "infobip": ("src.providers.infobip", "InfobipProvider"),
    "sinch": ("src.providers.sinch", "SinchProvider"),
    "soprano": ("src.providers.soprano", "SopranoProvider"),
    "telesign": ("src.providers.telesign", "TelesignProvider"),
}


def load_provider(provider_id):
    target = _PROVIDERS.get(provider_id)
    if target is None:
        return None
    module_name, class_name = target
    return getattr(importlib.import_module(module_name), class_name)()

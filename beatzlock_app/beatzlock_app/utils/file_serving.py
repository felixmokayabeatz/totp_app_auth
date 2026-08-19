import mimetypes
import os
from urllib.parse import quote

from django.conf import settings
from django.http import FileResponse, Http404, HttpResponse


def x_accel_file_response(file_field, *, as_attachment=True, download_name=None):
    """Serve a Django FileField through nginx via X-Accel-Redirect in
    production so the bytes never stream through a Gunicorn worker (fast,
    non-blocking downloads). Falls back to a normal FileResponse in DEBUG."""
    file_path = file_field.path
    if not os.path.exists(file_path):
        raise Http404("File not found")

    name = (file_field.name or "").replace("\\", "/")
    download_name = download_name or os.path.basename(file_path)
    content_type, _ = mimetypes.guess_type(file_path)
    content_type = content_type or "application/octet-stream"
    disposition = "attachment" if as_attachment else "inline"

    if getattr(settings, "USE_X_ACCEL_REDIRECT", not settings.DEBUG):
        response = HttpResponse(content_type=content_type)
        response["X-Accel-Redirect"] = "/internal-media/" + quote(name)
    else:
        response = FileResponse(open(file_path, "rb"), content_type=content_type)

    response["Content-Disposition"] = f'{disposition}; filename="{download_name}"'
    response["Accept-Ranges"] = "bytes"
    return response

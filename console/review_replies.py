from urllib.parse import urlencode

from django.contrib import messages
from django.contrib.admin.views.decorators import staff_member_required
from django.shortcuts import get_object_or_404, redirect, render
from django.utils import timezone
from django.utils.dateparse import parse_datetime
from django.utils.html import strip_tags
from django.utils.text import Truncator

from beatzlock_app.models import AppRating
from beatzlock_app.review_replies import dispatch_review_reply


def _reply_status_label(entry):
    if entry.get("admin_reply_sent_at"):
        return "Delivered"
    if str(entry.get("admin_reply") or "").strip():
        return "Draft reply"
    return "Needs reply"


def _preview_text(value, *, length=120):
    text = strip_tags(value or "").strip()
    if not text:
        return ""
    return Truncator(text).chars(length)


def _entry_datetime(entry, key, fallback=None):
    value = entry.get(key)
    if isinstance(value, str):
        parsed = parse_datetime(value)
        if parsed is not None:
            return parsed
    return fallback


def _entry_matches_search(rating, entry, search):
    haystacks = [
        rating.display_name,
        rating.account_email,
        rating.account_username,
        entry.get("comment"),
        entry.get("suggestion"),
        entry.get("admin_reply"),
        entry.get("device_label"),
        entry.get("app_version"),
        entry.get("build_number"),
    ]
    search = search.lower()
    return any(search in str(value or "").lower() for value in haystacks)


def _reply_entry_payload(rating, platform, entry):
    return {
        "platform": platform,
        "platform_label": rating.platform_label_for(platform),
        "stars": int(entry.get("stars") or rating.stars or 1),
        "comment_preview": _preview_text(entry.get("comment")),
        "suggestion_preview": _preview_text(entry.get("suggestion")),
        "admin_reply_preview": _preview_text(entry.get("admin_reply")),
        "reply_text": str(entry.get("admin_reply") or ""),
        "reply_status_label": _reply_status_label(entry),
        "created_at": _entry_datetime(entry, "created_at", rating.created_at),
        "updated_at": _entry_datetime(entry, "updated_at", rating.updated_at),
        "admin_replied_at": _entry_datetime(entry, "admin_replied_at"),
        "admin_reply_sent_at": _entry_datetime(entry, "admin_reply_sent_at"),
        "useful_count": int(entry.get("useful_count") or 0),
    }


def _reply_counts(queryset, *, platform="", search=""):
    counts = {"total": 0, "pending": 0, "draft": 0, "sent": 0}
    for rating in queryset:
        for entry_platform in rating.platform_values:
            if platform and entry_platform != platform:
                continue
            entry = rating.get_platform_review(entry_platform)
            if not entry:
                continue
            if search and not _entry_matches_search(rating, entry, search):
                continue
            counts["total"] += 1
            status = _reply_status_label(entry)
            if status == "Needs reply":
                counts["pending"] += 1
            elif status == "Draft reply":
                counts["draft"] += 1
            elif status == "Delivered":
                counts["sent"] += 1
    return counts


def _reply_groups(queryset, *, platform="", status_filter="", search=""):
    groups = []
    for index, rating in enumerate(queryset, start=1):
        entries = []
        for entry_platform in rating.platform_values:
            if platform and entry_platform != platform:
                continue
            entry = rating.get_platform_review(entry_platform)
            if not entry:
                continue
            if search and not _entry_matches_search(rating, entry, search):
                continue
            payload = _reply_entry_payload(rating, entry_platform, entry)
            if status_filter == "pending" and payload["reply_status_label"] != "Needs reply":
                continue
            if status_filter == "draft" and payload["reply_status_label"] != "Draft reply":
                continue
            if status_filter == "sent" and payload["reply_status_label"] != "Delivered":
                continue
            entries.append(payload)

        if not entries:
            continue

        entries.sort(
            key=lambda item: (
                item["updated_at"] or item["created_at"] or timezone.datetime.min
            ).isoformat(),
            reverse=True,
        )
        groups.append({
            "group_id": f"reply-group-{index}",
            "rating_id": rating.pk,
            "display_name": rating.display_name_or_anonymous,
            "account_email": rating.account_email,
            "account_username": rating.account_username,
            "entries": entries,
            "active_platform": entries[0]["platform"],
        })

    groups.sort(
        key=lambda item: (
            item["entries"][0]["updated_at"] or item["entries"][0]["created_at"] or timezone.datetime.min
        ).isoformat(),
        reverse=True,
    )
    return groups[:80]


@staff_member_required
def review_replies(request):
    if request.method == "POST":
        rating = get_object_or_404(AppRating, pk=request.POST.get("rating_id"))
        platform = rating.normalize_platform((request.POST.get("platform") or "").strip().lower())
        entry = rating.get_platform_review(platform)
        action = (request.POST.get("action") or "save_reply").strip().lower()
        next_url = request.POST.get("next") or request.path

        if not entry:
            messages.error(request, "That platform review could not be found.")
            return redirect(next_url)

        if action == "delete_reply":
            entry["admin_reply"] = ""
            entry["admin_replied_at"] = None
            entry["admin_reply_sent_at"] = None
            entry["admin_reply_by_id"] = None
            entry["admin_reply_by_name"] = ""
            rating.set_platform_review(platform, entry)
            rating.sync_summary_fields(platform)
            rating.save(update_fields=[
                "platform",
                "platform_history",
                "platform_reviews",
                "stars",
                "comment",
                "suggestion",
                "app_version",
                "build_number",
                "device_label",
                "admin_reply",
                "admin_replied_at",
                "admin_reply_sent_at",
                "useful_count",
                "updated_at",
            ])
            messages.success(request, f"Reply removed for the {rating.platform_label_for(platform)} review.")
            return redirect(next_url)

        reply_text = str(request.POST.get("admin_reply") or "").strip()
        if not reply_text:
            messages.error(request, "Write a reply before sending it.")
            return redirect(next_url)

        now_iso = timezone.now().isoformat()
        entry["admin_reply"] = reply_text
        entry["admin_replied_at"] = now_iso
        entry["admin_reply_by_id"] = request.user.pk
        entry["admin_reply_by_name"] = request.user.get_username()
        entry["admin_reply_sent_at"] = None
        rating.set_platform_review(platform, entry)
        rating.admin_reply_by = request.user
        rating.sync_summary_fields(platform)
        rating.save()

        result = dispatch_review_reply(rating, platform=platform, entry=entry, reply_text=reply_text)
        if result["email_sent"] or result["notification_sent"]:
            entry["admin_reply_sent_at"] = timezone.now().isoformat()
            rating.set_platform_review(platform, entry)
            rating.sync_summary_fields(platform)
            rating.save(update_fields=[
                "platform",
                "platform_history",
                "platform_reviews",
                "stars",
                "comment",
                "suggestion",
                "app_version",
                "build_number",
                "device_label",
                "admin_reply",
                "admin_reply_by",
                "admin_replied_at",
                "admin_reply_sent_at",
                "useful_count",
                "updated_at",
            ])

        if result["errors"]:
            messages.warning(
                request,
                "Reply saved with delivery issues: " + " | ".join(result["errors"]),
            )
        else:
            messages.success(
                request,
                f"Reply sent for the {rating.platform_label_for(platform)} review.",
            )

        return redirect(next_url)

    platform = (request.GET.get("platform") or "").strip().lower()
    status_filter = (request.GET.get("status") or "").strip().lower()
    search = (request.GET.get("q") or "").strip()

    valid_platforms = {value: label for value, label in AppRating.PLATFORM_CHOICES}
    if platform not in valid_platforms:
        platform = ""
    if status_filter not in {"", "pending", "draft", "sent"}:
        status_filter = ""

    queryset = list(AppRating.objects.all().select_related("admin_reply_by"))
    groups = _reply_groups(
        queryset,
        platform=platform,
        status_filter=status_filter,
        search=search,
    )
    counts = _reply_counts(queryset, platform=platform, search=search)

    query_string = urlencode(
        {
            key: value
            for key, value in {
                "status": status_filter,
                "platform": platform,
                "q": search,
            }.items()
            if value
        }
    )
    current_path = request.path + (f"?{query_string}" if query_string else "")

    context = {
        "rating_groups": groups,
        "counts": counts,
        "platform": platform,
        "platform_choices": AppRating.PLATFORM_CHOICES,
        "status_filter": status_filter,
        "search_query": search,
        "current_path": current_path,
    }
    return render(request, "console/review_replies.html", context)

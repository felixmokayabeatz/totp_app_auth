from django.contrib import admin, messages
from django.utils import timezone
from django.utils.html import format_html

from .review_replies import dispatch_review_reply
from .models import (
    AppRating,
    AppRatingUsefulVote,
    AppRelease,
    DownloadDailyStat,
    DownloadableApp,
    DownloadStats,
    LegalPage,
    TotalDownloadCount,
)

try:
    from tinymce.widgets import TinyMCE
    TINYMCE_AVAILABLE = True
except ImportError:
    TINYMCE_AVAILABLE = False


@admin.register(AppRelease)
class AppReleaseAdmin(admin.ModelAdmin):
    list_display = ('version', 'build_number', 'released_at', 'is_major_release', 'keep_in_archive', 'has_notes', 'platform_count')
    list_filter = ('is_major_release', 'keep_in_archive', 'released_at')
    search_fields = ('version', 'build_number')
    readonly_fields = ('created_at',)

    fieldsets = (
        ('Version Info', {
            'description': (
                'This record is shared across all platforms. '
                'Create one AppRelease per version, then link each platform binary to it below.'
            ),
            'fields': ('version', 'build_number', 'released_at', 'is_major_release', 'keep_in_archive'),
        }),
        ('Release Notes', {
            'description': (
                'Upload a plain-text .txt file. '
                'Name it after the version, e.g. v1.2.3.txt. '
                'All line breaks and blank lines are preserved on the front end.'
            ),
            'fields': ('release_notes_file',),
        }),
        ('Metadata', {
            'fields': ('created_at',),
            'classes': ('collapse',),
        }),
    )

    def has_notes(self, obj):
        return bool(obj.release_notes_file)
    has_notes.boolean = True
    has_notes.short_description = "Notes?"

    def platform_count(self, obj):
        return obj.platform_builds.filter(is_active=True).count()
    platform_count.short_description = "Active Platforms"

    def has_add_permission(self, request):
        return request.user.is_superuser

    def has_change_permission(self, request, obj=None):
        return request.user.is_superuser

    def has_delete_permission(self, request, obj=None):
        return request.user.is_superuser


@admin.register(DownloadableApp)
class DownloadableAppAdmin(admin.ModelAdmin):
    list_display = ('name', 'platform', 'linux_distribution', 'release', 'file_size_display', 'is_active', 'updated_at', 'download_count')
    list_filter = ('platform', 'linux_distribution', 'is_active', 'release')
    search_fields = ('name', 'platform', 'linux_distribution', 'release__version')
    readonly_fields = ('created_at', 'updated_at', 'file_size_display')

    fieldsets = (
        ('App Information', {
            'fields': ('name', 'platform', 'linux_distribution', 'release'),
            'description': (
                'Select the App Release (version) this binary belongs to. '
                'For Linux builds, choose the distro flavor before uploading the binary. '
                'Version number, build number and release notes all come from that release record.'
            ),
        }),
        ('Binary File', {
            'fields': ('file',),
        }),
        ('Status', {
            'fields': ('is_active',),
        }),
        ('Metadata', {
            'fields': ('created_at', 'updated_at', 'file_size_display'),
            'classes': ('collapse',),
        }),
    )

    def file_size_display(self, obj):
        return obj.file_size
    file_size_display.short_description = "File Size"

    def download_count(self, obj):
        total = sum(stat.download_count for stat in obj.stats.all())
        return f"{total:,}"
    download_count.short_description = "Total Downloads"

    def has_add_permission(self, request):
        return request.user.is_superuser

    def has_change_permission(self, request, obj=None):
        return request.user.is_superuser

    def has_delete_permission(self, request, obj=None):
        return request.user.is_superuser


@admin.register(LegalPage)
class LegalPageAdmin(admin.ModelAdmin):
    list_display = ('page_type', 'title', 'last_updated')
    readonly_fields = ('last_updated',)

    fieldsets = (
        (None, {
            'fields': ('page_type', 'title', 'content', 'last_updated'),
            'description': (
                'Write your content using the TinyMCE editor. '
                'Headings, lists, links, tables and inline styles are preserved on the front end.'
            ),
        }),
    )

    def formfield_for_dbfield(self, db_field, request, **kwargs):
        if db_field.name == 'content' and TINYMCE_AVAILABLE:
            kwargs['widget'] = TinyMCE()
        return super().formfield_for_dbfield(db_field, request, **kwargs)

    def has_add_permission(self, request):
        return request.user.is_superuser

    def has_change_permission(self, request, obj=None):
        return request.user.is_superuser

    def has_delete_permission(self, request, obj=None):
        return request.user.is_superuser



@admin.register(AppRating)
class AppRatingAdmin(admin.ModelAdmin):
    list_display = (
        'display_name_or_anonymous',
        'stars',
        'platform_label',
        'account_email',
        'reply_status',
        'useful_count',
        'is_approved',
        'created_at',
        'updated_at',
    )
    list_filter = ('platform', 'stars', 'is_approved', 'created_at', 'admin_replied_at')
    search_fields = (
        'display_name',
        'reviewer_key',
        'comment',
        'suggestion',
        'device_label',
        'app_version',
        'build_number',
        'account_email',
        'account_username',
        'account_user_id',
    )
    readonly_fields = (
        'reviewer_key',
        'platform_history',
        'platform_reviews',
        'account_user_id',
        'account_email',
        'account_username',
        'created_at',
        'updated_at',
        'useful_count',
        'admin_replied_at',
        'admin_reply_sent_at',
        'admin_reply_by',
    )

    fieldsets = (
        ('Review', {
            'fields': (
                'display_name',
                'platform',
                'platform_history',
                'platform_reviews',
                'reviewer_key',
                'stars',
                'comment',
                'suggestion',
                'is_approved',
            ),
        }),
        ('Admin Reply', {
            'description': 'Write a reply here to send it by email and as an in-app BeatzLock notification.',
            'fields': ('admin_reply', 'admin_replied_at', 'admin_reply_sent_at', 'admin_reply_by'),
        }),
        ('Linked App Account', {
            'fields': ('account_user_id', 'account_email', 'account_username'),
        }),
        ('App Details', {
            'fields': ('app_version', 'build_number', 'device_label'),
        }),
        ('Public Signals', {
            'fields': ('useful_count', 'created_at', 'updated_at'),
            'classes': ('collapse',),
        }),
    )

    @admin.display(description='Platform')
    def platform_label(self, obj):
        return obj.platform_label

    @admin.display(description='Reply status')
    def reply_status(self, obj):
        if obj.admin_reply_sent_at:
            return f"Sent {obj.admin_reply_sent_at:%Y-%m-%d %H:%M}"
        if obj.admin_reply.strip():
            return 'Saved only'
        return 'No reply'

    def save_model(self, request, obj, form, change):
        previous_reply = ''
        if change and obj.pk:
            previous_reply = (
                AppRating.objects.filter(pk=obj.pk)
                .values_list('admin_reply', flat=True)
                .first()
                or ''
            )

        reply_changed = obj.admin_reply.strip() != previous_reply.strip()
        if reply_changed and obj.admin_reply.strip():
            obj.admin_replied_at = timezone.now()
            obj.admin_reply_by = request.user

        entry = obj.get_platform_review(obj.platform) or {}
        if entry:
            entry['admin_reply'] = obj.admin_reply
            entry['admin_replied_at'] = obj.admin_replied_at.isoformat() if obj.admin_replied_at else None
            entry['admin_reply_by_id'] = request.user.pk if reply_changed and obj.admin_reply.strip() else entry.get('admin_reply_by_id')
            entry['admin_reply_by_name'] = request.user.get_username() if reply_changed and obj.admin_reply.strip() else entry.get('admin_reply_by_name')
            entry['admin_reply_sent_at'] = None if reply_changed else entry.get('admin_reply_sent_at')
            obj.set_platform_review(obj.platform, entry)
            obj.sync_summary_fields(obj.platform)

        super().save_model(request, obj, form, change)

        if not (reply_changed and obj.admin_reply.strip()):
            return

        result = dispatch_review_reply(obj, platform=obj.platform, entry=entry, reply_text=obj.admin_reply)
        if result['email_sent'] or result['notification_sent']:
            obj.admin_reply_sent_at = timezone.now()
            entry = obj.get_platform_review(obj.platform) or {}
            entry['admin_reply_sent_at'] = obj.admin_reply_sent_at.isoformat()
            obj.set_platform_review(obj.platform, entry)
            obj.save(update_fields=['platform', 'platform_history', 'platform_reviews', 'admin_reply_sent_at', 'updated_at'])

        if result['errors']:
            self.message_user(
                request,
                'Reply saved with delivery issues: ' + ' | '.join(result['errors']),
                level=messages.WARNING,
            )
        else:
            self.message_user(
                request,
                'Reply saved and delivered by email and in-app notification.',
                level=messages.SUCCESS,
            )

    def has_add_permission(self, request):
        return request.user.is_superuser

    def has_change_permission(self, request, obj=None):
        return request.user.is_superuser

    def has_delete_permission(self, request, obj=None):
        return request.user.is_superuser


@admin.register(AppRatingUsefulVote)
class AppRatingUsefulVoteAdmin(admin.ModelAdmin):
    list_display = ('rating', 'platform', 'voter_key', 'created_at')
    list_filter = ('platform', 'created_at',)
    readonly_fields = ('rating', 'platform', 'voter_key', 'created_at')

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return request.user.is_superuser

@admin.register(DownloadStats)
class DownloadStatsAdmin(admin.ModelAdmin):
    list_display = ('app', 'flag', 'country_name', 'download_count', 'last_downloaded')
    list_filter = ('country_name', 'last_downloaded')
    search_fields = ('app__name', 'country_name')
    readonly_fields = ('app', 'country_name', 'country_code', 'download_count', 'last_downloaded')

    def flag(self, obj):
        if obj.country_code and len(obj.country_code) == 2:
            return format_html(
                '<img src="https://flagcdn.com/w20/{}.png" style="border-radius:2px;">',
                obj.country_code.lower(),
            )
        return "Unknown"
    flag.short_description = ""

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return request.user.is_superuser


@admin.register(DownloadDailyStat)
class DownloadDailyStatAdmin(admin.ModelAdmin):
    list_display = ('download_date', 'app', 'flag', 'country_name', 'download_count', 'last_downloaded')
    list_filter = ('download_date', 'country_name', 'last_downloaded')
    search_fields = ('app__name', 'country_name', 'country_code')
    readonly_fields = ('download_date', 'app', 'country_name', 'country_code', 'download_count', 'last_downloaded')

    def flag(self, obj):
        if obj.country_code and len(obj.country_code) == 2:
            return format_html(
                '<img src="https://flagcdn.com/w20/{}.png" style="border-radius:2px;">',
                obj.country_code.lower(),
            )
        return "Unknown"
    flag.short_description = ""

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return request.user.is_superuser


@admin.register(TotalDownloadCount)
class TotalDownloadCountAdmin(admin.ModelAdmin):
    list_display = ('total_downloads', 'updated_at')
    readonly_fields = ('total_downloads', 'updated_at')

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

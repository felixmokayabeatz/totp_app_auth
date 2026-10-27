from django import forms
from django.contrib import admin, messages
from django.contrib.admin.forms import AdminAuthenticationForm
from django.contrib.auth.admin import UserAdmin as BaseUserAdmin
from django.contrib.auth.forms import UserChangeForm, UserCreationForm
from django.contrib.auth.models import User
from django.utils import timezone
from django.urls import reverse
from django.utils.html import format_html
from django.forms import Textarea

from .identity import find_user_by_login_identifier, normalize_email
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

class LegalContentEditor(Textarea):
    class Media:
        js = (
            'https://cdn.jsdelivr.net/npm/tinymce@7/tinymce.min.js',
            'beatzlock_app/admin_legal_tinymce.js',
        )

    def __init__(self, attrs=None):
        editor_attrs = {
            'class': 'beatzlock-legal-tinymce',
            'rows': 24,
            'placeholder': (
                'Write the legal page content here. Use headings, lists, links '
                'and tables as needed.'
            ),
        }
        editor_attrs.update(attrs or {})
        super().__init__(attrs=editor_attrs)


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
    """Every save creates or edits a *revision*, and revisions start as drafts.

    Nothing here publishes on save. You write, save, look at it with "Preview",
    and only then tick Published -- at which point the revision that was live
    slides into the public archive instead of being overwritten.
    """

    list_display = (
        'page_type',
        'title',
        'app_version',
        'status_badge',
        'published_at',
        'last_updated',
    )
    list_filter = ('page_type', 'is_published')
    search_fields = ('title', 'app_version')
    readonly_fields = ('published_at', 'created_at', 'last_updated', 'live_links')
    actions = ('publish_revisions', 'unpublish_revisions', 'duplicate_as_draft')
    ordering = ('page_type', '-published_at', '-created_at')

    fieldsets = (
        ('Document', {
            'fields': ('page_type', 'title', 'app_version'),
            'description': (
                'One record is one revision. To change a live document, do not edit it here -- '
                'select it in the list and run "Duplicate as a new draft", edit the copy, '
                'then publish the copy. The original stays readable in the public archive.'
            ),
        }),
        ('Content', {
            'fields': ('content',),
            'description': (
                'Write your content using the TinyMCE editor. '
                'Headings, lists, links, tables and inline styles are preserved on the front end.'
            ),
        }),
        ('Publishing', {
            'fields': ('is_published', 'published_at', 'live_links'),
            'description': (
                'A new record is a draft: invisible to users and to the app until you tick '
                'Published. Publishing this revision moves the currently live one to the archive.'
            ),
        }),
        ('Record', {
            'fields': ('created_at', 'last_updated'),
            'classes': ('collapse',),
        }),
    )

    @admin.display(description='Status')
    def status_badge(self, obj):
        if not obj.is_published:
            colour, label = '#b8860b', 'Draft'
        elif obj.is_current:
            colour, label = '#1a7f37', 'Live'
        else:
            colour, label = '#6b7280', 'Archived'
        return format_html(
            '<span style="color:{};font-weight:600;">&#9679; {}</span>', colour, label
        )

    @admin.display(description='Links')
    def live_links(self, obj):
        if not obj or not obj.pk:
            return 'Save this revision first, then a preview link appears here.'

        page_name = 'legal_terms' if obj.page_type == 'terms' else 'legal_privacy'
        archive_name = (
            'legal_terms_archive' if obj.page_type == 'terms' else 'legal_privacy_archive'
        )
        page_url = reverse('beatzlock_app:{}'.format(page_name))
        archive_url = reverse('beatzlock_app:{}'.format(archive_name))
        return format_html(
            '<a href="{}?preview={}" target="_blank">Preview this revision</a> &nbsp;|&nbsp; '
            '<a href="{}" target="_blank">Live document</a> &nbsp;|&nbsp; '
            '<a href="{}" target="_blank">Public archive</a>',
            page_url, obj.pk, page_url, archive_url,
        )

    @admin.action(description='Publish selected revisions')
    def publish_revisions(self, request, queryset):
        published = 0
        for revision in queryset.filter(is_published=False):
            revision.is_published = True
            revision.save()
            published += 1

        if published:
            self.message_user(
                request,
                f"Published {published} revision(s). Any revision they replaced is now in the archive.",
                messages.SUCCESS,
            )
        else:
            self.message_user(request, 'Nothing to publish -- all selected revisions were already published.', messages.INFO)

    @admin.action(description='Move selected back to draft (unpublish)')
    def unpublish_revisions(self, request, queryset):
        updated = queryset.filter(is_published=True).update(is_published=False)
        if updated:
            self.message_user(
                request,
                f"Moved {updated} revision(s) back to draft. If one of them was live, the "
                f"previous published revision is now live again.",
                messages.WARNING,
            )
        else:
            self.message_user(request, 'Nothing to unpublish.', messages.INFO)

    @admin.action(description='Duplicate as a new draft')
    def duplicate_as_draft(self, request, queryset):
        """The intended way to revise a live document: copy it, edit the copy."""
        created = 0
        for revision in queryset:
            revision.pk = None
            revision.id = None
            revision.is_published = False
            revision.published_at = None
            revision.save()
            created += 1

        self.message_user(
            request,
            f"Created {created} draft copy(ies). Edit the copy, preview it, then publish it.",
            messages.SUCCESS,
        )

    def get_form(self, request, obj=None, **kwargs):
        request._legalpage_obj = obj
        return super().get_form(request, obj, **kwargs)

    def _app_version_choices(self, request):
        """Released versions, newest first, so the version is a click not a typo."""
        choices = []
        seen = set()
        for release in AppRelease.objects.all():
            if release.version in seen:
                continue
            seen.add(release.version)
            label = f"v{release.version}"
            if release.build_number:
                label += f" (build {release.build_number})"
            if release.released_at:
                label += f" - released {release.released_at:%d %b %Y}"
            choices.append((release.version, label))

        current = getattr(request, '_legalpage_obj', None)
        existing = current.app_version if current else ''
        if existing and existing not in seen:
            choices.append((existing, f"v{existing} (release record removed)"))

        return choices

    def formfield_for_dbfield(self, db_field, request, **kwargs):
        if db_field.name == 'content':
            kwargs['widget'] = LegalContentEditor()

        if db_field.name == 'app_version':
            choices = self._app_version_choices(request)
            if choices:
                return forms.ChoiceField(
                    choices=[('', '--- Not tied to a version ---')] + choices,
                    required=False,
                    label='App version',
                    help_text=(
                        'Pick the release this revision ships with. The list comes from '
                        'App Releases -- add the release there first if it is missing. '
                        'For your reference only; users never see it.'
                    ),
                )

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




class EmailAdminAuthenticationForm(AdminAuthenticationForm):
    """Sign in to the admin with an email address, like the rest of the site."""

    username = forms.CharField(
        label="Email",
        widget=forms.TextInput(
            attrs={"autofocus": True, "autocomplete": "email", "inputmode": "email"}
        ),
    )

    error_messages = {
        **AdminAuthenticationForm.error_messages,
        "invalid_login": (
            "Please enter the correct email and password for a staff account. "
            "Note that both fields may be case-sensitive."
        ),
    }

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.fields["username"].max_length = 254
        self.fields["username"].widget.attrs["maxlength"] = 254

    def clean_username(self):
        identifier = self.cleaned_data.get("username", "")
        user = find_user_by_login_identifier(identifier)
        return user.username if user is not None else identifier


admin.site.login_form = EmailAdminAuthenticationForm


class StaffCreationForm(UserCreationForm):
    email = forms.EmailField(label="Email address", required=True)

    class Meta(UserCreationForm.Meta):
        model = User
        fields = ("email",)

    def clean_email(self):
        email = normalize_email(self.cleaned_data.get("email"))
        if find_user_by_login_identifier(email) is not None:
            raise forms.ValidationError("An account already exists for this address.")
        return email

    def save(self, commit=True):
        user = super().save(commit=False)
        user.email = self.cleaned_data["email"]
        user.username = user.email
        if commit:
            user.save()
        return user


class StaffChangeForm(UserChangeForm):
    email = forms.EmailField(label="Email address", required=True)

    class Meta(UserChangeForm.Meta):
        model = User
        exclude = ("username",)

    def clean_email(self):
        email = normalize_email(self.cleaned_data.get("email"))
        clash = find_user_by_login_identifier(email)
        if clash is not None and clash.pk != self.instance.pk:
            raise forms.ValidationError("Another account already uses this address.")
        return email

    def save(self, commit=True):
        user = super().save(commit=False)
        user.username = user.email
        if commit:
            user.save()
            self.save_m2m()
        return user


admin.site.unregister(User)


@admin.register(User)
class StaffAdmin(BaseUserAdmin):
    add_form = StaffCreationForm
    form = StaffChangeForm
    list_display = ('email', 'first_name', 'last_name', 'is_staff', 'is_superuser', 'last_login')
    list_filter = ('is_staff', 'is_superuser', 'is_active')
    search_fields = ('email', 'first_name', 'last_name')
    ordering = ('email',)
    fieldsets = (
        (None, {'fields': ('email', 'password')}),
        ('Personal info', {'fields': ('first_name', 'last_name')}),
        ('Permissions', {
            'fields': ('is_active', 'is_staff', 'is_superuser', 'groups', 'user_permissions'),
        }),
        ('Important dates', {'fields': ('last_login', 'date_joined')}),
    )
    add_fieldsets = (
        (None, {
            'classes': ('wide',),
            'fields': ('email', 'password1', 'password2'),
        }),
    )

from django import template

register = template.Library()

@register.filter
def sum_attribute(queryset, attribute):
    """Sum a specific attribute across a queryset"""
    total = 0
    for obj in queryset:
        total += getattr(obj, attribute, 0)
    return total
import json
import os

from snapshotter.utils.models.settings_model import PreloaderConfig
from snapshotter.utils.models.settings_model import ProjectsConfig
from snapshotter.utils.models.settings_model import Settings

settings_file = open('config/settings.json', 'r')
settings_dict = json.load(settings_file)

_reporting = settings_dict.setdefault('reporting', {})
_missed_batch = os.environ.get('TELEGRAM_MISSED_BATCH_SIZE', '').strip()
if _missed_batch:
    try:
        _reporting['missed_snapshot_batch_size'] = int(_missed_batch)
    except ValueError:
        pass

settings: Settings = Settings(**settings_dict)

projects_config_path = settings.projects_config_path
projects_config_file = open(projects_config_path)
projects_config_dict = json.load(projects_config_file)
projects_config = ProjectsConfig(**projects_config_dict).config

# sanity check
# making sure all project types are unique
project_types = set()
for project in projects_config:
    project_types.add(project.project_type)
assert len(project_types) == len(projects_config)

preloaders_config_path = settings.preloaders_config_path
preloaders_config_file = open(preloaders_config_path)
preloaders_config_dict = json.load(preloaders_config_file)
preloaders_config = PreloaderConfig(**preloaders_config_dict)
preloaders = preloaders_config.preloaders

preloader_types = set()
for preloader in preloaders:
    preloader_types.add(preloader.task_type)
assert len(preloader_types) == len(preloaders), 'Duplicate preloader types found'

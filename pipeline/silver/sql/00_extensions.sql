-- Silver prerequisites: the spatial extensions and the schema itself.
--
-- The image (install/docker_compose.yml) installs postgresql-17-postgis-3 and
-- postgresql-17-h3, but nothing ever enabled them - without this step every
-- ST_* and h3_* call below fails with "function does not exist".
--
-- h3_postgis needs CASCADE: it depends on both h3 and postgis.

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS h3;
CREATE EXTENSION IF NOT EXISTS h3_postgis CASCADE;

CREATE SCHEMA IF NOT EXISTS silver;

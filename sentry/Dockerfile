ARG SENTRY_IMAGE
FROM ${SENTRY_IMAGE:-getsentry/sentry:latest}

COPY . /usr/src/sentry

# Install dependencies for LDAP authentication
RUN apt-get update && apt-get install -y build-essential libsasl2-dev python-dev libldap2-dev libssl-dev


# Hook for installing additional plugins
RUN if [ -s /usr/src/sentry/requirements.txt ]; then pip install -r /usr/src/sentry/requirements.txt; fi

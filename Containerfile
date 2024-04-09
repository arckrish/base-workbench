# This image provides a Python 3.9 environment you can use to run your Python
# applications.
FROM registry.redhat.io/ubi8/s2i-base:1-504.1712567735

EXPOSE 8080

ENV PYTHON_VERSION=3.9 \
    PATH=/opt/app-root/bin:$HOME/.local/bin/:$PATH \
    PYTHONUNBUFFERED=1 \
    PYTHONIOENCODING=UTF-8 \
    LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    CNB_STACK_ID=com.redhat.stacks.ubi9-python-39 \
    CNB_USER_ID=1001 \
    CNB_GROUP_ID=0 \
    PIP_NO_CACHE_DIR=off

RUN INSTALL_PKGS="python39 python39-devel python39-setuptools python39-pip nss_wrapper \
        httpd httpd-devel mod_ssl mod_auth_gssapi mod_ldap \
        mod_session atlas-devel gcc-gfortran libffi-devel libtool-ltdl \
        enchant krb5-devel mesa-libGL" && \
    yum -y --setopt=tsflags=nodocs install $INSTALL_PKGS && \
    rpm -V $INSTALL_PKGS && \
    # Remove redhat-logos-httpd (httpd dependency) to keep image size smaller.
    rpm -e --nodeps redhat-logos-httpd && \
    yum -y clean all --enablerepo='*'

# Copy extra files to the image.
COPY root/ /

# - Create a Python virtual environment for use by any application to avoid
#   potential conflicts with Python packages preinstalled in the main Python
#   installation.
# - In order to drop the root user, we have to make some directories world
#   writable as OpenShift default security model is to run the container
#   under random UID.
RUN \
    python3.9 -m venv ${APP_ROOT} && \
    # Python 3.7+ only code, Python <3.7 installs pip from PyPI in the assemble script. \
    # We have to upgrade pip to a newer verison because: \
    # * pip < 9 does not support different packages' versions for Python 2/3 \
    # * pip < 19.3 does not support manylinux2014 wheels. Only manylinux2014 (and later) wheels \
    #   support platforms like ppc64le, aarch64 or armv7 \
    # We are newly using wheel from one of the latest stable Fedora releases (from RPM python-pip-wheel) \
    # because it's tested better then whatever version from PyPI and contains useful patches. \
    # We have to do it here (in the macro) so the permissions are correctly fixed and pip is able \
    # to reinstall itself in the next build phases in the assemble script if user wants the latest version \
    ${APP_ROOT}/bin/pip install /opt/pip-* && \
    rm -r /opt/pip-* && \
    chown -R 1001:0 ${APP_ROOT} && \
    fix-permissions ${APP_ROOT} -P && \
    rpm-file-permissions && \
    # The following echo adds the unset command for the variables set below to the \
    # venv activation script. This is inspired from scl_enable script and prevents \
    # the virtual environment to be activated multiple times and also every time \
    # the prompt is rendered. \
    echo "unset BASH_ENV PROMPT_COMMAND ENV" >> ${APP_ROOT}/bin/activate

# For RHEL/Centos 8+ scl_enable isn't sourced automatically in s2i-core
# so virtualenv needs to be activated this way
ENV BASH_ENV="${APP_ROOT}/bin/activate" \
    ENV="${APP_ROOT}/bin/activate" \
    PROMPT_COMMAND=". ${APP_ROOT}/bin/activate"

WORKDIR /opt/app-root/bin

# Install micropipenv to deploy packages from Pipfile.lock
RUN pip install --no-cache-dir -U "micropipenv[toml]"

COPY utils utils/

# Install Python dependencies from Pipfile.lock file
COPY Pipfile.lock start-notebook.sh ./

RUN echo "Installing softwares and packages" && micropipenv install && rm -f ./Pipfile.lock

# Disable announcement plugin of jupyterlab
RUN jupyter labextension disable "@jupyterlab/apputils-extension:announcements"

# Install the oc client
RUN curl -L https://mirror.openshift.com/pub/openshift-v4/$(uname -m)/clients/ocp/stable/openshift-client-linux.tar.gz \
        -o /tmp/openshift-client-linux.tar.gz && \
    tar -xzvf /tmp/openshift-client-linux.tar.gz oc && \
    rm -f /tmp/openshift-client-linux.tar.gz

# Fix permissions to support pip in Openshift environments
RUN chmod -R g+w /opt/app-root/lib/python3.9/site-packages && \
      fix-permissions /opt/app-root -P && chmod +x /opt/app-root/bin/start-notebook.sh

USER 1001

WORKDIR /opt/app-root/src

# Replace Notebook's launcher, "(ipykernel)" with Python's version 3.x.y
RUN sed -i -e "s/Python.*/$(python --version | cut -d '.' -f-2)\",/" /opt/app-root/share/jupyter/kernels/python3/kernel.json

ENTRYPOINT ["start-notebook.sh"]
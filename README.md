# Jenkins Docker Image with Docker Socket Support

This Docker image extends the official Jenkins image (`jenkins/jenkins:jdk21`) with additional tools and Docker socket mounting capabilities.

## Features

- **Base**: Jenkins with JDK 21
- **Additional Tools**:
  - Docker socket support via group membership
  - kubectl for Kubernetes deployments
  - Rust toolchain via rustup
  - Chromium for headless browser testing
  - Various utilities: rsync, gettext-base, xvfb, jq

## Docker Socket Mounting

This image includes special handling for Docker socket mounting:

```dockerfile
RUN groupadd -g 988 docker
RUN usermod -aG docker jenkins
```

### Important Note on Group ID

The Docker group is created with GID `988`. **This may cause issues on different host systems** where the Docker group has a different GID.

To check your host's Docker group ID:

```bash
getent group docker
```

If your Docker group has a different GID, you have two options:

1. **Rebuild the image** with your system's Docker GID:

   ```dockerfile
   RUN groupadd -g $(stat -c '%g' /var/run/docker.sock) docker
   ```

2. **Use --group-add when running**:
   ```bash
   docker run --group-add $(getent group docker | cut -d: -f3) ...
   ```

## Usage

### Quick Start

```bash
docker build -t jenkins-docker .
docker run -d -p 8080:8080 -v /var/run/docker.sock:/var/run/docker.sock jenkins-docker
```

### Production Setup

```bash
docker run -d \
  --name jenkins \
  -p 8080:8080 \
  -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  jenkins-docker
```

## Environment Variables

- `CHROME_BIN`: Set to `/usr/bin/chromium` for headless browser testing

## Security Considerations

Mounting the Docker socket gives Jenkins full access to the Docker daemon. Only use this in trusted environments and consider using Docker-in-Docker alternatives for production setups.

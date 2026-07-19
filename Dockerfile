# Use the official lightweight Python image.
# https://hub.docker.com/_/python
FROM python:3.11-slim

# Allow statements and log messages to immediately appear in the logs
ENV PYTHONUNBUFFERED=True

# Copy local code to the container image.
ENV APP_HOME=/app
WORKDIR $APP_HOME
COPY . ./

# Install production dependencies.
RUN pip install --no-cache-dir -r requirements.txt

# Run the web service on container startup.
# We use Gunicorn with 1 worker and 8 threads for handling parallel requests.
# Timeout is set to 0 to disable Gunicorn timeouts, allowing Cloud Run to manage instance lifetimes.
CMD exec gunicorn --bind 0.0.0.0:$PORT --workers 1 --threads 8 --timeout 0 app:app

FROM node:22-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY server.js ./

ARG APP_VERSION=v1
ARG BREAK_HEALTH=false
ENV APP_VERSION=${APP_VERSION} BREAK_HEALTH=${BREAK_HEALTH}

USER node
EXPOSE 3000
CMD ["node", "server.js"]

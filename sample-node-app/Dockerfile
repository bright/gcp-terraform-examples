
# Set the base image
FROM node:20-alpine

# Set the working directory
WORKDIR /usr/src/app

# Install app dependencies by copying
# package.json and package-lock.json
COPY package*.json ./

# Install all the dependencies
RUN npm install

# Bundle the app source inside the Docker image
COPY . .

# Your app binds to port 8080 so
# you use the EXPOSE instruction to have it mapped by the docker daemon
EXPOSE 8080

# Define the command to run your app using npm start script
CMD [ "npm", "start" ]

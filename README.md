# FotoJson.com

FotoJson is a photo organizer.

This page started out as the single "Stoned Eyeballs" image. It has
grown considerably, and is now primarily an example of how I build
user interface code.

## How to set up

You can use it for your own site, by changing `./site/.sshdir` to output an SSH heading for your site, copying `./site/images/index-sample.json` to `index.json`, and editing it to reflect the images you want to initially appear.

The `bin/update-site` to copy the files to your site.

## Development

To compile the Elm code into JavaScript in `site/elm.js`:

    bin/build
    
Do development by starting `elm reactor` in the `fotojson`
directory, then aiming your browser at
http://localhost:8000/site/index.html. Each time you build, you can
full-reload the browser tab.

To upload the code to FotoJson.com (if you're me), `bin/update-site`.

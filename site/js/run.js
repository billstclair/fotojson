//////////////////////////////////////////////////////////////////////
//
// run.js
// Run the Elm code.
// Add some port implementations.
// Copyright (c) 2025 Bill St. Clair <billstclair@gmail.com>
// Some rights reserved.
// Distributed under the MIT License
// See LICENSE
//
//////////////////////////////////////////////////////////////////////

(() => {
  var app = Elm.Main.init();
  PortFunnel.subscribe(app);

  // Call the selectElement port with an element ID string
  // to select its contents
  var selectElement = app.ports.selectElement;
  if (selectElement) {
    selectElement.subscribe(function(id) {
      var element = document.getElementById(id);
      if (element) {
        element.select();
      };
    });
  }

  // Clipboard support
  // Three ports:
  //   clipboardWrite <string>
  //   clipboardRead <ignored arg>
  //   clipboardContents (<string> sent here after clipboardRead())
  if (navigator && navigator.clipboard) {
    var clipboardWrite = navigator.clipboard.writeText &&
        app.ports.clipboardWrite;
    if (clipboardWrite) {
      clipboardWrite.subscribe(function(text) {
        if (typeof(text) == 'string') {
          try {
            navigator.clipboard.writeText(text);
          } catch (error) {
            console.error("clipboard.writeText failed:", error);
          }
        }
      });
    }
    var clipboardContents = app.ports.clipboardContents;
    if (clipboardContents) {
      var clipboardRead = navigator.clipboard.readText &&
          app.ports.clipboardRead;
      if (clipboardRead) {
        clipboardRead.subscribe(function() {
          try {
            navigator.clipboard.readText().then(function(data) {
              clipboardContents.send(data);
            })
              .catch(function(err) {});
          } catch (error) {
            console.error("clipboard.readText failed:", error);
          }
        });
      }
    }                
  }
})()

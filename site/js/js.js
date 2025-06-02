//////////////////////////////////////////////////////////////////////
//
// js.js
// Load the JS files needed by FotoJson.
// Copyright (c) 2025 Bill St. Clair <billstclair@gmail.com>
// Some rights reserved.
// Distributed under the MIT License
// See LICENSE
//
//////////////////////////////////////////////////////////////////////

(() => {
  function loadScript(url) {
       const script = document.createElement('script');
       script.src = url;
       script.type = 'text/javascript';
       document.head.appendChild(script);
  }

  loadScript('js/PortFunnel.js');
  loadScript('js/PortFunnel/LocalStorage.js');
})()

package ar.afelixc.consultacuit;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.print.PrintAttributes;
import android.print.PrintManager;
import android.webkit.JavascriptInterface;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.HashMap;
import java.util.Map;

/**
 * Envuelve la app web de la carpeta docs/ (copiada dentro del APK en assets/www).
 * Las páginas se sirven desde una dirección https interna, así que la app funciona
 * sin GitHub Pages; solo las consultas al BCRA usan internet.
 */
public class MainActivity extends Activity {

    private static final String HOST_APP = "appassets.androidplatform.net";
    private static final String INICIO = "https://" + HOST_APP + "/index.html";
    private static final String HOST_BCRA = "api.bcra.gob.ar";

    // Reemplaza en el WebView lo que solo existe en Chrome: compartir, copiar, imprimir y color de la barra.
    private static final String PUENTE_JS =
        "(function(){if(window.__appAndroid)return;window.__appAndroid=1;" +
        "navigator.share=function(d){d=d||{};AppAndroid.compartir(d.title||'',d.text||d.url||'');return Promise.resolve();};" +
        "try{Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:function(t){AppAndroid.copiar(String(t));return Promise.resolve();}}});}catch(e){}" +
        "window.print=function(){AppAndroid.imprimir(document.title||'Consulta CUIT BCRA');};" +
        "var m=document.querySelector('meta[name=theme-color]');" +
        "if(m){var f=function(){AppAndroid.color(m.content);};f();" +
        "new MutationObserver(f).observe(m,{attributes:true,attributeFilter:['content']});}" +
        "})();";

    private WebView web;

    @Override
    protected void onCreate(Bundle guardado) {
        super.onCreate(guardado);
        web = new WebView(this);
        setContentView(web);

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);   // historial y guardados (localStorage)
        s.setDatabaseEnabled(true);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);

        web.addJavascriptInterface(new Puente(), "AppAndroid");
        web.setWebChromeClient(new WebChromeClient());
        web.setWebViewClient(new Cliente());

        if (guardado == null || web.restoreState(guardado) == null) web.loadUrl(INICIO);
    }

    @Override
    protected void onSaveInstanceState(Bundle estado) {
        super.onSaveInstanceState(estado);
        web.saveState(estado);
    }

    @Override
    public void onBackPressed() {
        // Si está abierta la ventana de guardados, "Atrás" la cierra; si no, sale de la app.
        web.evaluateJavascript(
            "(function(){var h=document.getElementById('hoja');" +
            "if(h&&h.classList.contains('abierta')){h.classList.remove('abierta');return 1;}return 0;})()",
            new ValueCallback<String>() {
                @Override public void onReceiveValue(String v) {
                    if (!"1".equals(v)) MainActivity.super.onBackPressed();
                }
            });
    }

    private class Cliente extends WebViewClient {
        @Override
        public WebResourceResponse shouldInterceptRequest(WebView vista, WebResourceRequest pedido) {
            Uri u = pedido.getUrl();
            String host = u.getHost();
            if (HOST_APP.equals(host)) return archivoLocal(u.getPath());
            if (HOST_BCRA.equals(host) && "GET".equalsIgnoreCase(pedido.getMethod())) return consultarBcra(u.toString());
            return null;
        }

        @Override
        @SuppressWarnings("deprecation")
        public boolean shouldOverrideUrlLoading(WebView vista, String url) {
            Uri u = Uri.parse(url);
            if (HOST_APP.equals(u.getHost())) return false;
            // Cualquier otro enlace (por ejemplo, la descarga del programa de PC) se abre en el navegador.
            try { startActivity(new Intent(Intent.ACTION_VIEW, u)); } catch (ActivityNotFoundException e) { }
            return true;
        }

        @Override
        public void onPageFinished(WebView vista, String url) {
            vista.evaluateJavascript(PUENTE_JS, null);
        }
    }

    /** Sirve los archivos de la app desde assets/www. */
    private WebResourceResponse archivoLocal(String ruta) {
        if (ruta == null || ruta.equals("/") || ruta.isEmpty()) ruta = "/index.html";
        String nombre = "www" + ruta;
        try {
            InputStream in = getAssets().open(nombre);
            WebResourceResponse r = new WebResourceResponse(tipo(nombre), "utf-8", in);
            Map<String, String> h = new HashMap<String, String>();
            h.put("Cache-Control", "no-cache");
            r.setResponseHeaders(h);
            return r;
        } catch (IOException e) {
            return new WebResourceResponse("text/plain", "utf-8", 404, "Not Found",
                new HashMap<String, String>(), new ByteArrayInputStream(new byte[0]));
        }
    }

    private static String tipo(String n) {
        if (n.endsWith(".html")) return "text/html";
        if (n.endsWith(".js")) return "application/javascript";
        if (n.endsWith(".css")) return "text/css";
        if (n.endsWith(".png")) return "image/png";
        if (n.endsWith(".json") || n.endsWith(".webmanifest")) return "application/json";
        if (n.endsWith(".svg")) return "image/svg+xml";
        return "application/octet-stream";
    }

    /**
     * Hace la consulta al BCRA desde Android (sin restricciones de CORS del navegador).
     * Si falla la conexión devuelve null y el WebView la intenta por su cuenta.
     */
    private WebResourceResponse consultarBcra(String url) {
        HttpURLConnection c = null;
        try {
            c = (HttpURLConnection) new URL(url).openConnection();
            c.setConnectTimeout(20000);
            c.setReadTimeout(30000);
            c.setRequestProperty("Accept", "application/json");
            int codigo = c.getResponseCode();
            InputStream in = codigo >= 400 ? c.getErrorStream() : c.getInputStream();
            byte[] cuerpo = leer(in);
            String tipo = c.getContentType();
            if (tipo == null) tipo = "application/json";
            String mime = tipo.split(";")[0].trim();
            String motivo = c.getResponseMessage();
            if (motivo == null || motivo.trim().isEmpty()) motivo = codigo < 400 ? "OK" : "Error";
            Map<String, String> h = new HashMap<String, String>();
            h.put("Access-Control-Allow-Origin", "*");
            h.put("Cache-Control", "no-store");
            return new WebResourceResponse(mime, "utf-8", codigo, motivo, h, new ByteArrayInputStream(cuerpo));
        } catch (Exception e) {
            return null;
        } finally {
            if (c != null) c.disconnect();
        }
    }

    private static byte[] leer(InputStream in) throws IOException {
        if (in == null) return new byte[0];
        try {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] b = new byte[8192];
            int n;
            while ((n = in.read(b)) != -1) out.write(b, 0, n);
            return out.toByteArray();
        } finally {
            in.close();
        }
    }

    /** Funciones que la página llama como AppAndroid.xxx(...) */
    private class Puente {
        @JavascriptInterface
        public void compartir(final String titulo, final String texto) {
            runOnUiThread(new Runnable() { public void run() {
                Intent i = new Intent(Intent.ACTION_SEND);
                i.setType("text/plain");
                i.putExtra(Intent.EXTRA_SUBJECT, titulo);
                i.putExtra(Intent.EXTRA_TEXT, texto);
                try { startActivity(Intent.createChooser(i, "Compartir")); } catch (ActivityNotFoundException e) { }
            }});
        }

        @JavascriptInterface
        public void copiar(final String texto) {
            runOnUiThread(new Runnable() { public void run() {
                ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                if (cm != null) cm.setPrimaryClip(ClipData.newPlainText("Consulta CUIT", texto));
            }});
        }

        @JavascriptInterface
        public void imprimir(final String titulo) {
            runOnUiThread(new Runnable() { public void run() {
                PrintManager pm = (PrintManager) getSystemService(Context.PRINT_SERVICE);
                if (pm != null) pm.print(titulo, web.createPrintDocumentAdapter(titulo), new PrintAttributes.Builder().build());
            }});
        }

        @JavascriptInterface
        public void color(final String c) {
            runOnUiThread(new Runnable() { public void run() {
                try { getWindow().setStatusBarColor(Color.parseColor(c.trim())); } catch (Exception e) { }
            }});
        }
    }
}

// Puts the caption for whatever the video is playing into the bar underneath it.
//
// Underneath, never over: a caption drawn on the frame hides the part of the
// application it is talking about, which is the one thing a recorded walkthrough
// cannot afford. A native <track> would render inside the video element, so the
// cues are held here and the bar is an ordinary element the page lays out.
//
// The beats come down as an attribute rather than through an event because they
// do not change while the video plays - the recording is finished by the time
// there is anything to play.
export const DemoCaptions = {
  mounted() {
    this.beats = JSON.parse(this.el.dataset.beats || "[]");
    this.video = this.el.querySelector("video");
    this.caption = this.el.querySelector("#demo-caption");

    this.onTime = () => this.paint(this.video.currentTime * 1000);
    this.video.addEventListener("timeupdate", this.onTime);
    this.video.addEventListener("seeked", this.onTime);

    // A beat in the list is an index into the video, so clicking one plays from
    // there. The rows live outside this hook, which is why the listener is on
    // the document rather than on them.
    this.onSeek = (event) => {
      const row = event.target.closest("[data-at-ms]");
      if (!row) return;

      this.video.currentTime = Number(row.dataset.atMs) / 1000;
      this.video.play();
    };
    document.addEventListener("click", this.onSeek);

    this.paint(0);
  },

  destroyed() {
    this.video.removeEventListener("timeupdate", this.onTime);
    this.video.removeEventListener("seeked", this.onTime);
    document.removeEventListener("click", this.onSeek);
  },

  // The beat playing is the last one stamped at or before now. Nothing before
  // the first one: a recording opens on whatever was already on screen, and
  // captioning that with the first beat puts the words up before they were said.
  paint(atMs) {
    const playing = this.beats.filter((beat) => beat.at_ms <= atMs).pop();

    this.caption.textContent = playing ? playing.text : "";

    document.querySelectorAll("[data-at-ms]").forEach((row) => {
      if (playing && Number(row.dataset.atMs) === playing.at_ms) {
        row.setAttribute("aria-current", "true");
      } else {
        row.removeAttribute("aria-current");
      }
    });
  }
};

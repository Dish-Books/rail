// A few pixels short of the end still counts as the end, so sub-pixel rounding does not stop it following.
const MARGIN = 4;

export function atEnd({ scrollHeight, scrollTop, clientHeight }) {
  return scrollHeight - scrollTop - clientHeight <= MARGIN;
}

export function scrollTopFor({ scrollHeight }, following, place) {
  return following ? scrollHeight : place;
}

// Only the box's own scrollTop is set: scrollIntoView or focus would move the conversation around it too.
export const CommandOutput = {
  mounted() {
    this.following = true;
    this.place = 0;
    this.el.scrollTop = scrollTopFor(this.el, this.following, this.place);

    this.onScroll = () => {
      this.following = atEnd(this.el);
      this.place = this.el.scrollTop;
    };

    this.el.addEventListener("scroll", this.onScroll);
  },

  updated() {
    this.el.scrollTop = scrollTopFor(this.el, this.following, this.place);
  },

  destroyed() {
    this.el.removeEventListener("scroll", this.onScroll);
  }
};

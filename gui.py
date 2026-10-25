"""Simple cross-platform Tk GUI for plickass. Run: python3 gui.py"""
import os
import queue
import sys
import threading
import tkinter as tk
from contextlib import redirect_stdout
from tkinter import filedialog, messagebox, scrolledtext, ttk

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from correlate import PlexampCorrelate
from plexampDownloadCopier import PlexampDownloadCopier


def default_offline_dir():
    """Same default locations the command-line version checks."""
    try:
        import platform
        system = platform.system().lower()
        home = os.environ.get('HOME', '')
        if system == 'darwin':
            p = os.path.join(home, 'Library', 'Application Support', 'Plexamp', 'Offline')
        elif system == 'windows':
            p = os.path.join(os.environ.get('LOCALAPPDATA', ''), 'Plexamp', 'Plexamp', 'Offline')
        else:
            p = os.path.join(home, '.local', 'share', 'Plexamp', 'Offline')
        return p if os.path.isdir(p) else ''
    except Exception:
        return ''


class QueueWriter:
    """Sends print() output from the copier into the log window."""
    def __init__(self, q):
        self.q = q
    def write(self, text):
        if text:
            self.q.put(text)
    def flush(self):
        pass


class App:
    def __init__(self, root):
        self.root = root
        self.q = queue.Queue()
        self.running = False
        root.title('plickass')
        # Explicit colors: Apple's bundled Tk 8.5 otherwise draws labels/fields invisibly on recent macOS.
        bg, fg, field = '#f4f4f4', '#1d1d1f', '#ffffff'
        root.configure(bg=bg)
        root.option_add('*Background', bg)
        root.option_add('*Foreground', fg)
        root.option_add('*highlightBackground', bg)
        root.option_add('*Entry.Background', field)
        root.option_add('*Entry.insertBackground', fg)
        root.option_add('*Entry.relief', 'solid')
        root.option_add('*Entry.borderWidth', 1)
        root.option_add('*Text.Background', field)
        root.option_add('*Text.insertBackground', fg)
        root.option_add('*Text.relief', 'solid')
        root.option_add('*Text.borderWidth', 1)
        root.option_add('*selectBackground', '#b3d7ff')
        root.option_add('*selectForeground', fg)
        root.geometry('640x440')
        root.minsize(480, 320)

        frm = ttk.Frame(root, padding=12)
        frm.pack(fill='both', expand=True)
        frm.columnconfigure(1, weight=1)

        ttk.Label(frm, text='Plexamp downloads:').grid(row=0, column=0, sticky='w')
        self.src = tk.StringVar(value=default_offline_dir())
        ttk.Entry(frm, textvariable=self.src).grid(row=0, column=1, sticky='ew', padx=6)
        ttk.Button(frm, text='Browse…', command=self.pick_src).grid(row=0, column=2)

        ttk.Label(frm, text='Copy music to:').grid(row=1, column=0, sticky='w', pady=(8, 0))
        self.dst = tk.StringVar(value=os.path.join(os.path.expanduser('~'), 'Music', 'Plexamp Copies'))
        ttk.Entry(frm, textvariable=self.dst).grid(row=1, column=1, sticky='ew', padx=6, pady=(8, 0))
        ttk.Button(frm, text='Browse…', command=self.pick_dst).grid(row=1, column=2, pady=(8, 0))

        self.btn = ttk.Button(frm, text='Copy Music', command=self.start, width=16)
        self.btn.grid(row=2, column=0, columnspan=3, pady=12)

        self.log = scrolledtext.ScrolledText(frm, height=14, state='disabled', wrap='word')
        self.log.grid(row=3, column=0, columnspan=3, sticky='nsew')
        frm.rowconfigure(3, weight=1)

        self.status = tk.StringVar(value='Ready.')
        ttk.Label(frm, textvariable=self.status, anchor='w').grid(row=4, column=0, columnspan=3, sticky='ew', pady=(6, 0))

        self.root.after(100, self.drain)

    def pick_src(self):
        d = filedialog.askdirectory(title='Choose the Plexamp "Offline" folder', initialdir=self.src.get() or os.path.expanduser('~'))
        if d:
            self.src.set(d)

    def pick_dst(self):
        d = filedialog.askdirectory(title='Choose where to copy your music', initialdir=os.path.expanduser('~'))
        if d:
            self.dst.set(d)

    def append(self, text):
        self.log.configure(state='normal')
        self.log.insert('end', text)
        self.log.see('end')
        self.log.configure(state='disabled')

    def drain(self):
        try:
            while True:
                item = self.q.get_nowait()
                if isinstance(item, tuple) and item[0] == '__done__':
                    self.finish(item[1])
                else:
                    self.append(item)
        except queue.Empty:
            pass
        self.root.after(100, self.drain)

    def start(self):
        if self.running:
            return
        src, dst = self.src.get().strip(), self.dst.get().strip()
        if not src or not os.path.isdir(src):
            messagebox.showerror('Plexamp folder not found', 'Please choose the Plexamp "Offline" downloads folder.')
            return
        if not dst:
            messagebox.showerror('No destination', 'Please choose where to copy your music.')
            return
        if not os.path.isdir(dst):
            if not messagebox.askyesno('Create folder?', f'{dst}\n\ndoes not exist. Create it?'):
                return
            try:
                os.makedirs(dst)
            except OSError as e:
                messagebox.showerror('Could not create folder', str(e))
                return
        self.running = True
        self.btn.configure(state='disabled')
        self.status.set('Copying…')
        self.log.configure(state='normal')
        self.log.delete('1.0', 'end')
        self.log.configure(state='disabled')
        threading.Thread(target=self.work, args=(src, dst), daemon=True).start()

    def work(self, src, dst):
        error = None
        try:
            with redirect_stdout(QueueWriter(self.q)):
                correlator = PlexampCorrelate.__new__(PlexampCorrelate)
                correlator.appdir = src
                copier = PlexampDownloadCopier.__new__(PlexampDownloadCopier)
                copier.correlator = correlator
                copier.savepath = dst
                copier.copy()
        except Exception as e:
            error = f'{type(e).__name__}: {e}'
        self.q.put(('__done__', error))

    def finish(self, error):
        self.running = False
        self.btn.configure(state='normal')
        text = self.log.get('1.0', 'end')
        copied = text.count('Copying ')
        skipped = text.count('exists! Not copying')
        if error:
            self.append(f'\nERROR: {error}\n')
            self.status.set('Stopped with an error — see log.')
        else:
            self.status.set(f'Done. Copied {copied} file(s), skipped {skipped} already there.')
            if copied == 0 and skipped == 0:
                self.append('No downloaded tracks were found in that folder.\n')


if __name__ == '__main__':
    root = tk.Tk()
    App(root)
    # When launched from Finder, bring the window to the front.
    root.lift()
    root.attributes('-topmost', True)
    root.after(300, lambda: root.attributes('-topmost', False))
    root.focus_force()

    # Apple's Tk 8.5 on recent macOS leaves the window blank until it is resized; nudge it.
    def _nudge(step=0):
        root.update_idletasks()
        w, h = root.winfo_width(), root.winfo_height()
        root.geometry(f'{w + (1 if step == 0 else -1)}x{h}')
        if step == 0:
            root.after(50, lambda: _nudge(1))
    root.after(150, _nudge)
    root.mainloop()

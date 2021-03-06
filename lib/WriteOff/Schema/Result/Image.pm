use utf8;
package WriteOff::Schema::Result::Image;

use strict;
use warnings;
use base "WriteOff::Schema::Result";
use Digest::MD5;
use Imager;
use File::Spec;
use File::Copy;
use WriteOff::Util qw/simple_uri/;

__PACKAGE__->table("images");

__PACKAGE__->add_columns(
	"id",
	{ data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
	"hovertext",
	{ data_type => "text", is_nullable => 1 },
	"filesize",
	{ data_type => "integer", is_nullable => 0 },
	"mimetype",
	{ data_type => "text", is_nullable => 0 },
	"version",
	{ data_type => "text", is_nullable => 0 },
	"created",
	{ data_type => "timestamp", is_nullable => 1 },
	"updated",
	{ data_type => "timestamp", is_nullable => 1 },
);

__PACKAGE__->set_primary_key("id");

__PACKAGE__->belongs_to("entry", "WriteOff::Schema::Result::Entry", { image_id => "id" });
__PACKAGE__->has_many("image_stories", "WriteOff::Schema::Result::ImageStory", "image_id");
__PACKAGE__->many_to_many("storys", "image_stories", "story");

sub clean {
	my $self = shift;

	my $fn = $self->filename;
	for my $dir (qw{root/static/art root/static/art/thumb}) {
		for my $img (glob File::Spec->catfile($dir, $self->id . '-*')) {
			$img =~ qr{$fn$} or unlink $img;
		}
	}

	$self;
}

sub extension {
	return shift->mimetype =~ s{^image/}{}r =~ s{jpeg}{jpg}r;
}

sub filename {
	my $self = shift;
	return $self->id . '-' . $self->version . '.' .$self->extension;
}

sub id_uri {
	my $self = shift;

	return simple_uri $self->id, $self->title;
}

sub is_manipulable_by {
	my $self = shift;
	my $user = $self->result_source->schema->resultset('User')->resolve(shift)
		or return 0;

	return $user->is_admin
	    || $self->entry->event->is_organised_by($user)
	    || $self->entry->user_id == $user->id && $self->event->art_subs_allowed;
}

sub path {
	my ($self, $thumb) = @_;
	'/static/art/' . ('thumb/' x!! $thumb) . $self->filename;
}

sub title { shift->entry->title }

sub write {
	my ($self, $upload) = @_;
	$self->version(substr Digest::MD5->md5_hex(time . rand() . $$), -6);

	my $thumbpath = File::Spec->catfile('root', $self->path('thumb'));

	my $img = Imager->new(file => $upload) or die Imager->errstr . "\n";
	my $thumb = $img->scale(xpixels => 225, ypixels => 225, type => 'nonprop') or die $img->errstr . "\n";
	$thumb->write(file => $thumbpath, type => 'png') or die $thumb->errstr . "\n";

	if (!copy($upload, File::Spec->catfile('root', $self->path))) {
		my $e = $!;
		unlink $thumbpath;
		die "$e\n";
	}

	$self->clean;
}

1;
